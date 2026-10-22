package agent_product

import yjson_support.*

import yjson.*

import agent_host_runtime.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_client.*
import agent_core.*
import agent_domain.*
import agent_runtime.*
import task_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*

public class ProductSubagentSnapshot {
    public let id: String
    public let index: Int64
    public let agent: String
    public let agentSource: String
    public let description: String
    public let status: String
    public let task: String
    public let assignment: String
    public let sessionId: SessionId
    public let sessionRef: String
    public let runId: RunId
    public let parentRunId: RunId
    public let parentToolCallId: String
    public let lastUpdate: Int64
    public let depth: Int64
    public let requests: Int64
    public let tokens: Int64
    public let toolCount: Int64
    public let currentTool: String
    public let durationMillis: Int64
    public let error: String

    public init(
        id: String,
        index: Int64,
        agent: String,
        description: String,
        status: String,
        task: String,
        assignment: String,
        sessionId: SessionId,
        sessionRef: String,
        runId: RunId,
        parentRunId: RunId,
        parentToolCallId: String,
        lastUpdate: Int64,
        depth: Int64,
        requests: Int64,
        tokens: Int64,
        toolCount: Int64,
        currentTool: String,
        durationMillis: Int64,
        error!: String = "",
        agentSource!: String = "bundled"
    ) {
        this.id = id
        this.index = index
        this.agent = agent
        this.agentSource = agentSource
        this.description = description
        this.status = status
        this.task = task
        this.assignment = assignment
        this.sessionId = sessionId
        this.sessionRef = sessionRef
        this.runId = runId
        this.parentRunId = parentRunId
        this.parentToolCallId = parentToolCallId
        this.lastUpdate = lastUpdate
        this.depth = depth
        this.requests = requests
        this.tokens = tokens
        this.toolCount = toolCount
        this.currentTool = currentTool
        this.durationMillis = durationMillis
        this.error = error
    }
}

public class ProductSubagentEvent {
    public let kind: String
    public let snapshot: ProductSubagentSnapshot
    public let event: ?AgentEvent
    public let approval: ?ApprovalRequest

    public init(
        kind: String,
        snapshot: ProductSubagentSnapshot,
        event!: ?AgentEvent = None,
        approval!: ?ApprovalRequest = None
    ) {
        this.kind = kind
        this.snapshot = snapshot
        this.event = event
        this.approval = approval
    }
}

public type ProductSubagentEventSink = (ProductSubagentEvent) -> Unit

public class ProductSubagentTranscript {
    public let sessionRef: String
    public let fromItem: Int64
    public let nextItem: Int64
    public let reset: Bool
    public let messages: Array<ModelMessage>

    public init(
        sessionRef: String,
        fromItem: Int64,
        nextItem: Int64,
        reset: Bool,
        messages: Array<ModelMessage>
    ) {
        this.sessionRef = sessionRef
        this.fromItem = fromItem
        this.nextItem = nextItem
        this.reset = reset
        this.messages = messages
    }
}

class ProductSubagentState {
    let id: String
    let index: Int64
    let agent: String
    var agentSource: String
    let description: String
    let task: String
    let assignment: String
    let sessionId: SessionId
    let sessionRef: String
    var runId: RunId
    let parentRunId: RunId
    let parentSessionId: SessionId
    let parentToolCallId: String
    let depth: Int64
    let startedAt: Int64
    var status: String
    var lastUpdate: Int64
    var requests: Int64 = 0
    var tokens: Int64 = 0
    var toolCount: Int64 = 0
    var currentTool: String = ""
    var error: String = ""
    var pendingRequest: ?AgentRunRequest = None
    var pendingApproval: ?ApprovalRequest = None
    let recentApprovalDenials = ArrayList<String>()
    var capabilities: CapabilitySet
    let capabilityCeilingKnown: Bool
    // A live delegation authority is not reconstructible from a task snapshot.
    var budgetAuthority: ?ToolInvocationContext
    var budgetParentRunId: RunId
    var workflowPin: ?ProductWorkflowPin = None
    // Original, non-serializable completion custody. Snapshots keep only its
    // source identity; restart never reconstructs an executable continuation.
    var pluginAdmission111: ?HostPluginChildAdmission111 = None
    // The immutable original Main relationship never becomes authority for
    // another incarnation. Current budget/start custody may belong to a later
    // actual peer.send parent; the first parent's ACK proof stays separate.
    var pluginOriginalAdmission111: ?HostPluginChildAdmission111 = Option<HostPluginChildAdmission111>.None
    var pluginCurrentBudgetAuthority111: ?ToolInvocationContext = Option<ToolInvocationContext>.None
    var pluginCompletion111: ?AgentValue = None
    var pluginCompletionPending111: ?AgentValue = None
    var pluginProjectionPayment151: ?HostPaidValueProjection151 = Option<HostPaidValueProjection151>.None
    var pluginCompletionDone111 = false
    var pluginCancellationRequested111 = false
    var pluginStartAdmitted111 = false
    let pluginWorkers111 = ArrayList<ProductPluginChildPhysicalWorker111>()
    var pluginJobKey111: ?ProductAsyncJobKey = None
    var launchInProgress: Bool = false
    var executionInProgress: Bool = false
    var finishing: Bool = false
    let settlementLock:Mutex

    init(
        id: String,
        index: Int64,
        agent: String,
        description: String,
        task: String,
        assignment: String,
        sessionId: SessionId,
        sessionRef: String,
        runId: RunId,
        parentRunId: RunId,
        parentSessionId: SessionId,
        parentToolCallId: String,
        depth: Int64,
        agentSource!: String = "bundled",
        capabilities!: CapabilitySet = CapabilitySet(),
        capabilityCeilingKnown!: Bool = true,
        budgetAuthority!: ?ToolInvocationContext = None,
        startedAt!: Int64 = 0,
        status!: String = "running",
        lastUpdate!: Int64 = 0,
        settlementLock111!: ?Mutex = Option<Mutex>.None
    ) {
        this.settlementLock=settlementLock111 ?? Mutex()
        this.id = id
        this.index = index
        this.agent = agent
        this.agentSource = agentSource
        this.description = description
        this.task = task
        this.assignment = assignment
        this.sessionId = sessionId
        this.sessionRef = sessionRef
        this.runId = runId
        this.parentRunId = parentRunId
        this.parentSessionId = parentSessionId
        this.parentToolCallId = parentToolCallId
        this.depth = depth
        this.capabilities = capabilities
        this.capabilityCeilingKnown = capabilityCeilingKnown
        this.budgetAuthority = budgetAuthority
        this.budgetParentRunId = parentRunId
        this.status = status
        this.startedAt = if (startedAt > 0) { startedAt } else { nowMillis() }
        this.lastUpdate = if (lastUpdate > 0) { lastUpdate } else { this.startedAt }
    }

    func snapshot(): ProductSubagentSnapshot {
        ProductSubagentSnapshot(
            id,
            index,
            agent,
            description,
            status,
            task,
            assignment,
            sessionId,
            sessionRef,
            runId,
            parentRunId,
            parentToolCallId,
            lastUpdate,
            depth,
            requests,
            tokens,
            toolCount,
            currentTool,
            max(0, lastUpdate - startedAt),
            error: error,
            agentSource: agentSource
        )
    }
}

class ProductSubagentListener {
    let id: Int64
    private let frameLock = Mutex()
    private var sink: ?ProductSubagentEventSink
    private var activeFrames: Int64 = 0
    private var closing = false
    init(id: Int64, sink: ProductSubagentEventSink) { this.id = id; this.sink = Some(sink) }
    func invoke180(event: ProductSubagentEvent): Unit {
        frameLock.lock()
        try {
            if (closing) { return }
            if (activeFrames == Int64.Max) { throw IllegalStateException("control dispatch frame overflow") }
            activeFrames++
        } finally { frameLock.unlock() }
        try { invokeSinkHelper180(event) }
        finally { frameLock.lock(); try { activeFrames-- } finally { frameLock.unlock() } }
    }
    private func invokeSinkHelper180(event: ProductSubagentEvent): Unit {
        frameLock.lock(); let actual = try { sink.getOrThrow() } finally { frameLock.unlock() }
        actual(event)
    }
    func closeReturnedFrames180(): Bool {
        frameLock.lock()
        try {
            closing = true
            if (activeFrames != 0) { return false }
            sink = None<ProductSubagentEventSink>; true
        } finally { frameLock.unlock() }
    }
}

class ProductYieldSection {
    let labels: Array<String>
    let data: AgentValue

    init(labels: Array<String>, data: AgentValue) {
        this.labels = labels
        this.data = data
    }
}

class ProductYieldState {
    // Private CAS data; it cannot recover a child owner or authorize a write.
    var revision150: Int64 = 0
    let runId: RunId
    let sections = ArrayList<ProductYieldSection>()
    var terminal: ?AgentValue = None
    var error: String = ""
    var useLastTurn = false

    init(runId: RunId) {
        this.runId = runId
    }
}



class ProductSubagentReservation {
    let id: String
    let index: Int64

    init(id: String, index: Int64) {
        this.id = id
        this.index = index
    }
}


public class ProductAsyncJobSnapshot {
    public let id: String
    public let agentId: String
    public let jobType: String
    public let status: String
    public let label: String
    public let sessionId: SessionId
    public let ownerRunId: RunId
    public let operationId: String
    public let executing: Bool
    public let startedAt: Int64
    public let updatedAt: Int64
    public let durationMillis: Int64
    public let result: ?AgentValue
    public let error: String

    public init(
        id: String,
        agentId: String,
        jobType: String,
        status: String,
        label: String,
        sessionId: SessionId,
        ownerRunId: RunId,
        operationId: String,
        executing: Bool,
        startedAt: Int64,
        updatedAt: Int64,
        result: ?AgentValue,
        error: String
    ) {
        this.id = id
        this.agentId = agentId
        this.jobType = jobType
        this.status = status
        this.label = label
        this.sessionId = sessionId
        this.ownerRunId = ownerRunId
        this.operationId = operationId
        this.executing = executing
        this.startedAt = startedAt
        this.updatedAt = updatedAt
        this.durationMillis = max(0, updatedAt - startedAt)
        this.result = result
        this.error = error
    }
}

public class ProductAsyncJobEvent {
    public let kind: String
    public let snapshot: ProductAsyncJobSnapshot

    public init(kind: String, snapshot: ProductAsyncJobSnapshot) {
        this.kind = kind
        this.snapshot = snapshot
    }
}

public type ProductAsyncJobEventSink = (ProductAsyncJobEvent) -> Unit


class ProductAsyncJobListener {
    let id: Int64
    private let frameLock = Mutex()
    private var sink: ?ProductAsyncJobEventSink
    private var activeFrames: Int64 = 0
    private var closing = false
    init(id: Int64, sink: ProductAsyncJobEventSink) { this.id = id; this.sink = Some(sink) }
    func invoke180(event: ProductAsyncJobEvent): Unit {
        frameLock.lock()
        try {
            if (closing) { return }
            if (activeFrames == Int64.Max) { throw IllegalStateException("control dispatch frame overflow") }
            activeFrames++
        } finally { frameLock.unlock() }
        try { invokeSinkHelper180(event) }
        finally { frameLock.lock(); try { activeFrames-- } finally { frameLock.unlock() } }
    }
    private func invokeSinkHelper180(event: ProductAsyncJobEvent): Unit {
        frameLock.lock(); let actual = try { sink.getOrThrow() } finally { frameLock.unlock() }
        actual(event)
    }
    func closeReturnedFrames180(): Bool {
        frameLock.lock()
        try {
            closing = true
            if (activeFrames != 0) { return false }
            sink = None<ProductAsyncJobEventSink>; true
        } finally { frameLock.unlock() }
    }
}

public class ProductHubMessageSnapshot {
    public let id: String
    public let from: String
    public let to: String
    public let message: String
    public let replyTo: String
    public let createdAt: Int64

    public init(
        id: String,
        from: String,
        to: String,
        message: String,
        replyTo: String,
        createdAt: Int64
    ) {
        this.id = id
        this.from = from
        this.to = to
        this.message = message
        this.replyTo = replyTo
        this.createdAt = createdAt
    }
}

class ProductHubMessageState {
    let snapshot: ProductHubMessageSnapshot
    let targetSessionId: SessionId
    let rootSessionId: SessionId
    let waitCallId: String
    let reviveTarget: Bool
    let deliveryText111: ?String
    var consumed = false

    init(
        snapshot: ProductHubMessageSnapshot,
        targetSessionId: SessionId,
        rootSessionId: SessionId,
        waitCallId!: String = "",
        reviveTarget!: Bool = false,
        deliveryText111!: ?String = Option<String>.None,
        consumed!: Bool = false
    ) {
        this.snapshot = snapshot
        this.targetSessionId = targetSessionId
        this.rootSessionId = rootSessionId
        this.waitCallId = waitCallId
        this.reviveTarget = reviveTarget
        this.deliveryText111 = deliveryText111
        this.consumed = consumed
    }
}

class ProductHubIdentity {
    let id: String
    let sessionId: SessionId
    let rootSessionId: SessionId
    let parentToolCallId: String
    let status: String

    init(
        id: String,
        sessionId: SessionId,
        rootSessionId: SessionId,
        parentToolCallId!: String = "",
        status!: String = "running"
    ) {
        this.id = id
        this.sessionId = sessionId
        this.rootSessionId = rootSessionId
        this.parentToolCallId = parentToolCallId
        this.status = status
    }
}

// Display ids are intentionally scoped to a user session and may be reused.
// Every asynchronous worker captures this immutable generation key so a
// restored or pruned job with the same display id cannot receive its updates.
class ProductAsyncJobKey {
    let rootSessionId: SessionId
    let sessionId: SessionId
    let id: String
    let instanceId: Int64

    init(
        rootSessionId: SessionId,
        sessionId: SessionId,
        id: String,
        instanceId: Int64
    ) {
        this.rootSessionId = rootSessionId
        this.sessionId = sessionId
        this.id = id
        this.instanceId = instanceId
    }
}

class ProductAsyncJobTarget {
    let key: ProductAsyncJobKey
    let snapshot: ProductAsyncJobSnapshot

    init(key: ProductAsyncJobKey, snapshot: ProductAsyncJobSnapshot) {
        this.key = key
        this.snapshot = snapshot
    }
}

class ProductAsyncJobSelection {
    let snapshots: Array<ProductAsyncJobSnapshot>
    let settledAndDelivered: Bool

    init(snapshots: Array<ProductAsyncJobSnapshot>, settledAndDelivered: Bool) {
        this.snapshots = snapshots
        this.settledAndDelivered = settledAndDelivered
    }
}

class ProductAsyncJobState {
    let id: String
    let agentId: String
    let jobType: String
    let label: String
    let sessionId: SessionId
    let rootSessionId: SessionId
    let ownerRunId: RunId
    let instanceId: Int64
    let parentToolCallId: String
    let operationId: String
    let startedAt: Int64
    var status = "running"
    var updatedAt: Int64
    var result: ?AgentValue = None
    var error = ""
    var executing = false
    var settlementReceiptId = ""
    var settlementInjected = false
    var projectionPayment151: ?HostPaidValueProjection151 = Option<HostPaidValueProjection151>.None

    init(
        id: String,
        agentId: String,
        jobType: String,
        label: String,
        sessionId: SessionId,
        rootSessionId: SessionId,
        ownerRunId: RunId,
        instanceId: Int64,
        parentToolCallId!: String = "",
        operationId!: String = "",
        startedAt!: Int64 = 0,
        status!: String = "running",
        updatedAt!: Int64 = 0,
        result!: ?AgentValue = None,
        error!: String = "",
        executing!: Bool = false,
        settlementReceiptId!: String = "",
        settlementInjected!: Bool = false
    ) {
        this.id = id
        this.agentId = agentId
        this.jobType = jobType
        this.label = label
        this.sessionId = sessionId
        this.rootSessionId = rootSessionId
        this.ownerRunId = ownerRunId
        this.instanceId = instanceId
        this.parentToolCallId = parentToolCallId
        this.operationId = operationId
        this.startedAt = if (startedAt > 0) { startedAt } else { nowMillis() }
        this.status = status
        this.updatedAt = if (updatedAt > 0) { updatedAt } else { this.startedAt }
        this.result = result
        this.error = error
        this.executing = executing
        this.settlementReceiptId = settlementReceiptId
        this.settlementInjected = settlementInjected
    }

    func snapshot(): ProductAsyncJobSnapshot {
        ProductAsyncJobSnapshot(
            id,
            agentId,
            jobType,
            status,
            label,
            sessionId,
            ownerRunId,
            operationId,
            executing,
            startedAt,
            updatedAt,
            result,
            error
        )
    }

    func key(): ProductAsyncJobKey {
        ProductAsyncJobKey(rootSessionId, sessionId, id, instanceId)
    }
}

class ProductPeerWaitSelection171 { var value: ?ProductHubMessageState = None }

class ProductJobCancelCapture172 {
    let admission: HostPluginChildAdmission111
    let meter: HostPaidValueProjection151
    var failure: ?AgentError = None<AgentError>
    init(admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151) { this.admission=admission; this.meter=meter }
    func capture(error: AgentError): Unit {
        let paid=admission.retainFailure172(error)
        if (failure.isNone()) { failure=Some(paid) }
    }
    // emitJobEvent allocates ONE event/snapshot and passes its same reference
    // to every sink. This charge covers the extra listener-array references and
    // fixed wrappers. The complete graph is separately paid once by the actual
    // retained snapshot invoice; arbitrary legacy sink copies/mutation remain
    // outside a refundable alias protocol, never acknowledged by callback return.
    func fundSinkSnapshot(count: Int64): Unit {
        if (count<0 || count>(Int64.Max-16384)/2048) { throw LogicalJsonPayloadError("cancel sink invoice overflow") }
        meter.fundAdditional151(8192,count*2+8)
        admission.retainWorkerMetadata111(count*2048+16384)
    }
}

public class ProductTaskRuntime {
    private let lock = Mutex()
    private let records = ArrayList<ProductSubagentState>()
    private let listeners = ArrayList<ProductSubagentListener>()
    private let yields = ArrayList<ProductYieldState>()
    private let jobs = ArrayList<ProductAsyncJobState>()
    private let jobListeners = ArrayList<ProductAsyncJobListener>()
    private let hubMessages = ArrayList<ProductHubMessageState>()
    private let recoveryWarnings = ArrayList<ProductTaskRecoveryWarning>()
    private let tasks = TaskService(MemoryTaskRepository())
    private let asyncEnabled: Bool
    private let allowUnsafeDirectLaunchForTests: Bool
    private var product: ?ProductRuntime = None
    private var processSupervisor: ?ProductProcessSupervisor = None
    private var processOwner180: ?ActualProcessBrokerRoot180 = None<ActualProcessBrokerRoot180>
    private var taskPersistence: ?ProductTaskPersistence = None
    private let stateRevisions = HashMap<String, Int64>()
    private let childBudgetPools = HashMap<String, ChildBudgetPool>()
    private let childBudgetOrder = ArrayList<String>()
    private let childBudgetLeases = HashMap<String, ChildBudgetLease>()
    private let childUsage = HashMap<String, ExecutionUsage>()
    // Live cancellation/cleanup handles only. Facts and recovery remain in the
    // existing jobs journal, Runtime and Operation Store.
    private let managedJobs = HashMap<String, ProductManagedJobHandle>()
    // Raw background/snapshot readers currently have no lease-ACK contract.
    // Keep their exact data payments rooted; worker completion/prune/GC never
    // refunds them. Typed background consumption/retirement remains OPEN.
    private let projectionUnretired151 = ArrayList<HostPaidValueProjection151>()
    private let ownedWorkers = ArrayList<Future<Unit>>()
    private let ownedPluginWorkers111 = ArrayList<ProductPluginChildPhysicalWorker111>()
    private var closing = false
    private var listenerCounter: Int64 = 0
    private var jobListenerCounter: Int64 = 0
    private var subagentCounter: Int64 = 0
    private var jobCounter: Int64 = 0
    private var messageCounter: Int64 = 0

    public init(
        asyncEnabled!: Bool = true,
        allowUnsafeDirectLaunchForTests!: Bool = false
    ) {
        this.asyncEnabled = asyncEnabled
        this.allowUnsafeDirectLaunchForTests = allowUnsafeDirectLaunchForTests
    }

    func attach(value: ProductRuntime, persistence: ProductTaskPersistence, ownerRoot180!: ?ActualProcessBrokerRoot180 = None<ActualProcessBrokerRoot180>): Unit {
        var restored = false
        lock.lock()
        try {
            product = Some(value)
            processOwner180 = ownerRoot180
            processSupervisor = match (ownerRoot180) {
                case Some(owner) => owner.supervisor
                case None => Some(ProductProcessSupervisor(value.workspace,
                    sandboxEnabled: value.directProcessSandboxEnabled(),
                    allowUnsafeTestBypass: allowUnsafeDirectLaunchForTests,
                    shellNetworkMode: value.shellNetworkMode, sandboxCaBundle: value.sandboxCaBundle))
            }
            if (ownerRoot180.isNone()) { match (processSupervisor) { case Some(owner) => owner.initializeBrokerStorage180(); case None => () } }
            if (taskPersistence.isNone()) {
                taskPersistence = Some(persistence)
                let restoredRoots = persistence.loadAll()
                for (warning in persistence.warnings()) { recoveryWarnings.add(warning) }
                restoreTaskStateLocked(restoredRoots)
                restored = true
            }
        } finally {
            lock.unlock()
        }
        if (restored) {
            replayPendingSettlements()
        }
    }

    // Only this supervisor's actual spawn result enters the private state.
    // This observer is called outside that future's action. A worker finally
    // flag, a terminal Run, or a listener's callback return is not this proof.
    private func pluginWorkersReturnedLocked111(state: ProductSubagentState): Bool {
        if (state.pluginWorkers111.isEmpty()) { return false }
        for (worker in state.pluginWorkers111) {
            if (!worker.returned()) { return false }
        }
        true
    }

    private func startPluginWorker111<T>(state: ProductSubagentState,
        build: () -> (() -> Result<T>), idle!: Bool = false,
        cleanup!: Bool = false): Result<ProductPluginChildWorkerResult111<T>> {
        lock.lock()
        try {
            let actual = findSubagentLocked(state.id)
            if (actual.isNone() || !refEq(actual.getOrThrow(), state) ||
                state.pluginAdmission111.isNone() || state.finishing || (closing && !cleanup)) {
                return taskError("child.worker_owner_changed", "actual child worker custody is unavailable") }
            if (idle && (state.launchInProgress || state.executionInProgress ||
                !pluginWorkersReturnedLocked111(state))) {
                return taskError("child.execution_in_progress", "actual prior child worker has not returned") }
            if (ownedPluginWorkers111.size > (Int64.Max - 16384) / 128 ||
                state.pluginWorkers111.size > (Int64.Max - 16384) / 128) {
                return taskError("child.worker_metadata_overflow", "actual worker metadata invoice overflow") }
            try {
                // Both growing lists, holder, closure and future are paid
                // before construction. Existing request objects are retained
                // by their original owner; no data payment is released here.
                state.pluginAdmission111.getOrThrow().retainWorkerMetadata111(
                    16384 + ownedPluginWorkers111.size * 64 + state.pluginWorkers111.size * 64)
                let result = ProductPluginChildWorkerResult111<T>()
                // Register paid custody BEFORE spawn. A failed list growth or
                // action factory cannot leave an already running orphan.
                state.pluginWorkers111.add(result.physical)
                ownedPluginWorkers111.add(result.physical)
                let action = build()
                let worker = spawn { result.run(action) }
                result.physical.worker = Some(worker)
                // The action's first Task access waits for this lock. Its
                // exact future is installed before any claim can observe it.
                Result.Ok(result)
            } catch (_: Exception) {
                taskError("child.worker_start_failed", "actual child worker could not be supervised")
            }
        } finally { lock.unlock() }
    }

    private func pluginChildState111(id: String): Result<ProductSubagentState> {
        lock.lock()
        try {
            match (findSubagentLocked(id)) {
                case Some(state) =>
                    if (state.pluginAdmission111.isSome()) { Result.Ok(state) }
                    else { taskError("child.owner_missing", "actual installed child custody is unavailable") }
                case None => taskError("child.owner_missing", "actual installed child custody is unavailable")
            }
        } finally { lock.unlock() }
    }
    private func startOwnedWorker(action: () -> Unit): Result<Unit> {
        lock.lock()
        try {
            if (closing) {
                return Result.Err(AgentError(
                    AgentErrorKind.Cancelled,
                    "task.runtime_closing",
                    "task runtime is closing and cannot start background work"
                ))
            }
            try {
                ownedWorkers.add(spawn { action() })
                Result.Ok(())
            } catch (_: Exception) {
                taskError("task.worker_start_failed", "background worker could not be started")
            }
        } finally {
            lock.unlock()
        }
    }

    // Used only to preserve a real new continuation's backend through failed
    // shutdown. It is observation of this actual owner, never a loaded DTO.
    func hasPluginChildDebt111(): Bool {
        lock.lock()
        try {
            for (state in records where state.pluginAdmission111.isSome()) {
                if (!state.pluginCompletionDone111 || childBudgetLeases.get(state.id).isSome() ||
                    state.launchInProgress || state.executionInProgress || !pluginWorkersReturnedLocked111(state)) { return true }
            }
            false
        } finally { lock.unlock() }
    }
    // A non-mutating observation of this exact process-local owner. Terminal
    // DTOs are not join/receipt witnesses, and this grants no cleanup ACK.
    func hasOwnerLifetimeDebt180(): Bool {
        lock.lock()
        try {
            if (!managedJobs.isEmpty() || !childBudgetLeases.isEmpty() ||
                !projectionUnretired151.isEmpty() || !listeners.isEmpty() ||
                !jobListeners.isEmpty()) { return true }
            for (state in records) {
                if (state.launchInProgress || state.executionInProgress || state.finishing ||
                    state.pendingRequest.isSome() || state.pendingApproval.isSome() ||
                    state.status == "running" || state.status == "blocked" ||
                    state.pluginCompletionPending111.isSome() || state.pluginProjectionPayment151.isSome()) { return true }
                if (state.pluginAdmission111.isSome() && !state.pluginCompletionDone111) { return true }
            }
            for (job in jobs) {
                if (job.executing || job.status == "running" || !job.settlementInjected ||
                    job.projectionPayment151.isSome()) { return true }
            }
            for (message in hubMessages) { if (!message.consumed) { return true } }
            for (worker in ownedWorkers) {
                try { if (worker.tryGet().isNone()) { return true } }
                catch (_: Exception) { return true }
            }
            for (worker in ownedPluginWorkers111) { if (!worker.returned()) { return true } }
            false
        } finally { lock.unlock() }
    }

    public func close(): Result<Unit> {
        let targets = ArrayList<ProductSubagentSnapshot>()
        let jobTargets = ArrayList<ProductAsyncJobKey>()
        let workers: Array<Future<Unit>>
        let pluginWorkers111: Array<ProductPluginChildPhysicalWorker111>
        let supervisor: ?ProductProcessSupervisor
        let runtime: ?ProductRuntime
        lock.lock()
        try {
            closing = true
            for (record in records where record.status == "running" ||
                record.status == "blocked") {
                targets.add(record.snapshot())
            }
            for (job in jobs where job.status == "running") {
                jobTargets.add(job.key())
            }
            workers = ownedWorkers.toArray()
            pluginWorkers111 = ownedPluginWorkers111.toArray()
            supervisor = processSupervisor
            runtime = product
        } finally {
            lock.unlock()
        }
        match (runtime) {
            case Some(value) =>
                for (target in targets) {
                    if (isPluginChild111(target.id)) { let _ = cancelPluginChild111(value, target.id) }
                    else { let _ = value.client.cancel(target.runId) }
                }
                cancelJobKeys(value, jobTargets.toArray())
            case None => ()
        }
        match (supervisor) {
            case Some(value) => value.close()
            case None => ()
        }
        var firstError = ""
        for (worker in workers) {
            try {
                worker.get()
            } catch (error: Exception) {
                if (firstError == "") { firstError = error.message }
            }
        }
        for (worker in pluginWorkers111) {
            try { worker.collect() }
            catch (error: Exception) { if (firstError == "") { firstError = error.message } }
        }
        retryManagedCleanup()
        retryPluginChildCompletions111()
        lock.lock()
        try {
            if (!managedJobs.isEmpty() && firstError == "") {
                firstError = "managed job cleanup remains quarantined; its budget and resource handles are retained"
            }
            for (state in records where state.pluginAdmission111.isSome()) {
                if ((!state.pluginCompletionDone111 || childBudgetLeases.get(state.id).isSome()) && firstError == "") {
                    firstError = "plugin child completion or budget custody remains unsettled"
                }
            }
        } finally { lock.unlock() }
        if (firstError == "") {
            Result.Ok(())
        } else {
            Result.Err(AgentError(
                AgentErrorKind.Internal,
                "task.worker_join_failed",
                firstError
            ))
        }
    }

    private func restoreTaskStateLocked(values: Array<ProductTaskPersistedRoot>): Unit {
        for (root in values) {
            stateRevisions[root.rootSessionId.value] = root.revision
            subagentCounter = max(subagentCounter, root.subagentCounter)
            jobCounter = max(jobCounter, root.jobCounter)
            messageCounter = max(messageCounter, root.messageCounter)
            for (state in root.subagents) { records.add(state) }
            for (state in root.jobs) { jobs.add(state) }
            for (state in root.messages) { hubMessages.add(state) }
        }
        pruneSubagentsLocked()
        // Confirmed terminal generations are safe to prune during restore;
        // doing this before the normalized snapshot prevents an acknowledged
        // over-limit journal from requiring an extra replay write.
        pruneJobsLocked()
        pruneHubMessagesLocked()
        // Persist normalized recovery_required states and any cross-root bound
        // enforcement before settlement replay begins.
        let roots = taskRootIdsLocked()
        for (root in roots) {
            match (persistRootLocked(SessionId(root))) {
                case Result.Ok(_) => ()
                case Result.Err(error) => rememberTaskPersistenceFailureLocked(SessionId(root), error)
            }
        }
    }

    private func persistRootLocked(rootSessionId: SessionId): Result<Unit> {
        let persistence = match (taskPersistence) {
            case Some(value) => value
            case None => return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "task.persistence_unavailable",
                    "task persistence is not attached"
                )
            )
        }
        let subagents = ArrayList<ProductSubagentState>()
        for (state in records where state.parentSessionId.value == rootSessionId.value) {
            subagents.add(state)
        }
        let rootJobs = ArrayList<ProductAsyncJobState>()
        for (state in jobs where state.rootSessionId.value == rootSessionId.value) {
            rootJobs.add(state)
        }
        let messages = ArrayList<ProductHubMessageState>()
        for (state in hubMessages where state.rootSessionId.value == rootSessionId.value) {
            messages.add(state)
        }
        let previous = match (stateRevisions.get(rootSessionId.value)) {
            case Some(value) => value
            case None => 0
        }
        let revision = previous + 1
        let written = persistence.appendRoot(
            rootSessionId,
            revision,
            subagentCounter,
            jobCounter,
            messageCounter,
            subagents.toArray(),
            rootJobs.toArray(),
            messages.toArray()
        )
        match (written) {
            case Result.Ok(_) =>
                stateRevisions[rootSessionId.value] = revision
                Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func taskRootIdsLocked(): Array<String> {
        let values = ArrayList<String>()
        for ((root, _) in stateRevisions) { addTaskRoot(values, root) }
        for (state in records) { addTaskRoot(values, state.parentSessionId.value) }
        for (state in jobs) { addTaskRoot(values, state.rootSessionId.value) }
        for (state in hubMessages) { addTaskRoot(values, state.rootSessionId.value) }
        values.toArray()
    }

    private func persistAllTaskRootsLocked(): Result<Unit> {
        let roots = taskRootIdsLocked()
        for (root in roots) {
            match (persistRootLocked(SessionId(root))) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }

    private func rememberTaskPersistenceFailureLocked(
        rootSessionId: SessionId,
        error: AgentError
    ): Unit {
        let reason = error.message
        let file = "state.db"
        for (warning in recoveryWarnings where warning.rootSessionId == rootSessionId.value &&
            warning.file == file && warning.reason == reason) {
            return
        }
        recoveryWarnings.add(ProductTaskRecoveryWarning(rootSessionId.value, file, reason))
    }

    private func taskPersistenceRecoveryText(error: AgentError): String {
        "recovery_required: task persistence failed: " + error.message
    }

    private func markJobPersistenceRecoveryLocked(
        job: ProductAsyncJobState,
        error: AgentError
    ): Unit {
        job.status = "recovery_required"
        job.executing = false
        job.updatedAt = nowMillis()
        job.error = taskPersistenceRecoveryText(error)
        prepareJobSettlementLocked(job)
        job.settlementInjected = false
        rememberTaskPersistenceFailureLocked(job.rootSessionId, error)
    }

    private func markSubagentPersistenceRecoveryLocked(
        state: ProductSubagentState,
        error: AgentError
    ): Unit {
        state.status = "recovery_required"
        state.pendingRequest = None
        state.pendingApproval = None
        state.currentTool = ""
        state.lastUpdate = nowMillis()
        state.error = taskPersistenceRecoveryText(error)
        rememberTaskPersistenceFailureLocked(state.parentSessionId, error)
    }


    func recoveryWarningsForSession(sessionId: SessionId): Array<String> {
        lock.lock()
        try {
            let values = ArrayList<String>()
            for (warning in recoveryWarnings where warning.rootSessionId == sessionId.value ||
                warning.rootSessionId == "unknown") {
                values.add(warning.text())
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func subscribe(sink: ProductSubagentEventSink): Int64 {
        lock.lock()
        try {
            listenerCounter += 1
            listeners.add(ProductSubagentListener(listenerCounter, sink))
            listenerCounter
        } finally {
            lock.unlock()
        }
    }

    public func subscribeJobs(sink: ProductAsyncJobEventSink): Int64 {
        lock.lock()
        try {
            jobListenerCounter += 1
            jobListeners.add(
                ProductAsyncJobListener(
                    jobListenerCounter,
                    sink
                )
            )
            jobListenerCounter
        } finally {
            lock.unlock()
        }
    }
    public func unsubscribeSubagents180(id: Int64): Unit {
        while (true) {
            lock.lock()
            let returned = try {
                var complete = true
                for (index in 0..listeners.size where listeners[index].id == id) {
                    complete = listeners[index].closeReturnedFrames180()
                    if (complete) { listeners.remove(at: index) }; break
                }
                complete
            } finally { lock.unlock() }
            if (returned) { return }; sleep(Duration.millisecond)
        }
    }
    public func unsubscribeAsyncJobs180(id: Int64): Unit {
        while (true) {
            lock.lock()
            let returned = try {
                var complete = true
                for (index in 0..jobListeners.size where jobListeners[index].id == id) {
                    complete = jobListeners[index].closeReturnedFrames180()
                    if (complete) { jobListeners.remove(at: index) }; break
                }
                complete
            } finally { lock.unlock() }
            if (returned) { return }; sleep(Duration.millisecond)
        }
    }

    public func messageSubagent(
        rootSessionId: SessionId,
        subagentId: String,
        message: String
    ): Result<Unit> {
        let text = message.trimAscii()
        if (subagentId.trimAscii() == "" || text == "") {
            return taskError<Unit>(
                "hub.message_invalid",
                "subagent id and message are required"
            )
        }
        let suffix = nowMillis().toString()
        let authority: ?ToolInvocationContext
        lock.lock()
        try {
            let state = match (findSubagentLocked(subagentId)) {
                case Some(value) => value
                case None => return taskError<Unit>("subagent.not_found", "unknown subagent")
            }
            if (state.parentSessionId.value != rootSessionId.value) {
                return taskError<Unit>("subagent.not_found", "unknown subagent")
            }
            authority = state.budgetAuthority
            if (state.status != "running" && state.status != "blocked" && authority.isNone()) {
                return taskError<Unit>("child.redelegation_required",
                    "restored child has no live parent budget authority; delegate a new task")
            }
        } finally { lock.unlock() }
        match (deliverSubagentMessage196(
            ToolInvocationContext(
                RunId("tui-hub-" + suffix),
                rootSessionId,
                CapabilitySet()
            ),
            subagentId,
            text,
            "",
            budgetAuthority: authority
        )) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func cancelSubagent(
        rootSessionId: SessionId,
        subagentId: String
    ): Result<Unit> {
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let target = runningSubagent(rootSessionId, subagentId)
        if (target.isSome() && isPluginChild111(subagentId)) {
            return cancelPluginChild111(runtime, subagentId)
        }
        match (target) {
            case None => Result.Ok(())
            case Some(value) =>
                let _ = runtime.cancelApprovalReview(value.runId)
                let _ = tasks.transition(TaskId(value.id), TaskStatus.Cancelled)
                if (subagentStatus(value.id) != "cancelled") {
                    let _ = finishSubagent(value.id, "cancelled")
                }
                // The state becomes visible just before AgentClient.start
                // registers the run. Treat cancellation in that window as
                // idempotent, while briefly retrying so a concurrently
                // registering run is still stopped.
                for (_ in 0..50) {
                    match (runtime.client.cancel(value.runId)) {
                        case Result.Ok(_) => return Result.Ok(())
                        case Result.Err(error) =>
                            if (error.code != "persistence.not_found" &&
                                error.code != "run.sqlite_recovery_required") {
                                return Result.Err(error)
                            }
                    }
                    sleep(Duration.millisecond * 10)
                }
                Result.Ok(())
        }
    }

    public func decideSubagentApproval(
        rootSessionId: SessionId,
        subagentId: String,
        decision: ApprovalDecision
    ): Result<Unit> {
        if (!isPluginChild111(subagentId)) {
            return decideSubagentApprovalAction111(rootSessionId, subagentId, decision) }
        let state = match (pluginChildState111(subagentId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let stage = match (startPluginWorker111<Unit>(state,
            { => { => decideSubagentApprovalAction111(rootSessionId, subagentId, decision) } }, idle: true)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        stage.collect()
    }

    private func decideSubagentApprovalAction111(
        rootSessionId: SessionId,
        subagentId: String,
        decision: ApprovalDecision
    ): Result<Unit> {
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var pendingRequest: ?AgentRunRequest = None
        var pendingApproval: ?ApprovalRequest = None
        lock.lock()
        try {
            let state = match (findSubagentLocked(subagentId)) {
                case Some(value) => value
                case None => return taskError<Unit>(
                    "subagent.not_found",
                    "Unknown subagent: " + subagentId
                )
            }
            if (state.parentSessionId.value != rootSessionId.value) {
                return taskError<Unit>(
                    "subagent.not_found",
                    "Unknown subagent: " + subagentId
                )
            }
            if (state.executionInProgress || state.launchInProgress) {
                return taskError<Unit>("child.execution_in_progress", "child execution has not settled")
            }
            pendingRequest = state.pendingRequest
            pendingApproval = state.pendingApproval
            if (pendingRequest.isSome() && pendingApproval.isSome()) { state.executionInProgress = true }
        } finally {
            lock.unlock()
        }
        let request = match (pendingRequest) {
            case Some(value) => value
            case None => return taskError<Unit>(
                "subagent.no_pending_approval",
                "subagent has no pending approval"
            )
        }
        let approval = match (pendingApproval) {
            case Some(value) => value
            case None => return taskError<Unit>(
                "subagent.no_pending_approval",
                "subagent has no pending approval"
            )
        }
        try {
            match (validatePluginChildContinuation111(subagentId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let _ = tasks.transition(TaskId(subagentId), TaskStatus.Running)
            match (childRunAction(subagentId, { => runtime.client.decide(
                request,
                approval,
                decision,
                {event => recordChildEvent(subagentId, event)}
            ) })) {
                case Result.Err(error) =>
                    let ended = finishSubagent(subagentId, "failed", error: error.message)
                    if (ended.status == "recovery_required") {
                        taskError<Unit>("child.budget_recovery_required", ended.error)
                    } else { Result.Err(error) }
                case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                    applyRunSnapshot(subagentId, snapshot)
                    let ended = finishSubagent(subagentId, "completed")
                    if (ended.status == "completed") {
                        let _ = tasks.transition(TaskId(subagentId), TaskStatus.Completed)
                        Result.Ok(())
                    } else {
                        taskError<Unit>("child." + ended.status,
                            if (ended.error != "") { ended.error } else { "subagent ended as " + ended.status })
                    }
                case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, next)) =>
                    applyRunSnapshot(subagentId, snapshot)
                    let _ = markSubagentAwaitingApproval(subagentId, request, next)
                    let _ = tasks.transition(TaskId(subagentId), TaskStatus.Blocked)
                    Result.Ok(())
            }
        } finally { releaseChildExecution(subagentId) }
    }

    private func runningSubagent(
        rootSessionId: SessionId,
        subagentId: String
    ): ?ProductSubagentSnapshot {
        lock.lock()
        try {
            for (record in records where record.parentSessionId.value == rootSessionId.value && record.id == subagentId &&
                (record.status == "running" || record.status == "blocked")) {
                return Some(record.snapshot())
            }
            None
        } finally {
            lock.unlock()
        }
    }

    public func activeSubagents(rootSessionId: SessionId): Array<ProductSubagentSnapshot> {
        lock.lock()
        try {
            let values = ArrayList<ProductSubagentSnapshot>()
            for (record in records where record.parentSessionId.value == rootSessionId.value && (record.status ==
                "running" || record.status == "blocked")) {
                values.add(record.snapshot())
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func allSubagents(rootSessionId: SessionId): Array<ProductSubagentSnapshot> {
        lock.lock()
        try {
            let values = ArrayList<ProductSubagentSnapshot>()
            for (record in records where record.parentSessionId.value == rootSessionId.value) {
                values.add(record.snapshot())
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func transcript(
        rootSessionId: SessionId,
        subagentId!: String = "",
        sessionRef!: String = "",
        fromItem!: Int64 = 0
    ): Result<ProductSubagentTranscript> {
        if (fromItem < 0) {
            return taskError<ProductSubagentTranscript>(
                "subagent.invalid_cursor",
                "fromItem must be a finite non-negative number"
            )
        }
        let state = lockAndFindSubagent(
            rootSessionId,
            subagentId,
            sessionRef
        )
        let snapshot = match (state) {
            case Some(value) => value
            case None => return taskError<ProductSubagentTranscript>(
                "subagent.not_found",
                if (subagentId != "") {
                    "Unknown subagent: " + subagentId
                } else if (sessionRef != "") {
                    "Unknown subagent session reference"
                } else {
                    "get_subagent_messages requires subagentId or " + "sessionRef"
                }
            )
        }
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let canonical = match (runtime.threadItems(snapshot.sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let nextItem = if (canonical.isEmpty()) {
            1
        } else {
            canonical[canonical.size - 1].ordinal + 1
        }
        let reset = fromItem > nextItem
        let start = if (reset) {
            1
        } else if (fromItem < 1) {
            1
        } else {
            fromItem
        }
        let selected = ArrayList<ThreadItem>()
        for (item in canonical where item.ordinal >= start) {
            selected.add(item)
        }
        let messages = modelMessagesFromCanonicalItems(selected.toArray())
        Result.Ok(
            ProductSubagentTranscript(
                snapshot.sessionRef,
                start,
                nextItem,
                reset,
                messages
            )
        )
    }







    public func jobsFor(sessionId: SessionId): Array<ProductAsyncJobSnapshot> {
        // A managed worker can finish before its real resource cleanup ACK.
        // Observe that ACK outside the jobs lock before returning cached state;
        // retry only releases the cleanup owner, never Unknown effect or budget.
        retryManagedCleanup()
        retryPluginChildCompletions111()
        lock.lock()
        try {
            let values = ArrayList<ProductAsyncJobSnapshot>()
            for (job in jobs where job.sessionId.value == sessionId.value) {
                values.add(job.snapshot())
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    func startManagedJob(vnext: ProductVnextControl, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, acknowledged: () -> Bool): Result<ToolResult> {
        if (!asyncEnabled || !context.capabilities.allows(CapabilityKind.Delegate, resource: "managed-job") ||
            !isManagedJobLaunchPlan(prepared.operationPlan)) {
            return taskError("task.managed_job_denied", "managed jobs require explicit delegation and an approved frozen plan") }
        let reservation = match (vnext.reserveManagedJob(context, prepared)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let declaration = reservation.binding.declaration
        // This Task source cannot request a model or delegate again. Positive
        // model-token minima are descriptor constraints, refunded at zero use.
        let budget = ExecutionBudget(maxTurns: 1, maxModelRequests: 1, maxDrainModelRequests: 1,
            maxToolCalls: declaration.maxToolCalls, maxConcurrentTools: 1, maxInputTokens: 1, maxOutputTokens: 1,
            maxTotalInputTokens: 1, maxTotalOutputTokens: 1, maxCostMicros: if (context.budget.maxCostMicros > 0) { 1 } else { 0 },
            maxChildren: 0, maxDepth: 1, maxConcurrentChildren: 1,
            deadlineMillis: declaration.deadlineMillis, processLimits: context.budget.processLimits)
        match (reserveChildBudget(context, declaration.jobId, budget)) {
            case Result.Err(error) => reservation.cancel(); reservation.detachUnclaimedParent(); return Result.Err(error); case Result.Ok(_) => () }
        let handle = ProductManagedJobHandle(reservation, budget, ProductIds().nextOperationId(), acknowledged)
        let key: ProductAsyncJobKey
        let snapshot: ProductAsyncJobSnapshot
        lock.lock()
        try {
            var running: Int64 = 0
            for (value in jobs where value.status == "running") { running += 1 }
            if (closing || running >= 15 || managedJobs.contains(declaration.jobId)) {
                reservation.cancel(); reservation.detachUnclaimedParent()
                let _ = settleManagedBudgetLocked(declaration.jobId, ExecutionUsage())
                return taskError("async.capacity", "managed job capacity is unavailable") }
            jobCounter += 1
            let job = ProductAsyncJobState(declaration.jobId, declaration.runId.value, "managed", prepared.call.name,
                context.sessionId, hubIdentityLocked(context).rootSessionId, context.runId, jobCounter,
                parentToolCallId: prepared.call.callId, operationId: handle.operationId.value)
            jobs.add(job); managedJobs[job.id] = handle; key = job.key()
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Err(error) =>
                    reservation.cancel(); reservation.detachUnclaimedParent(); managedJobs.remove(job.id)
                    let _ = settleManagedBudgetLocked(job.id, ExecutionUsage())
                    markJobPersistenceRecoveryLocked(job, error); return Result.Err(error)
                case Result.Ok(_) => () }
            snapshot = job.snapshot()
        } finally { lock.unlock() }
        match (startOwnedWorker({ => runManagedJob(vnext, context, prepared.call, key, handle) })) {
            case Result.Err(error) =>
                reservation.cancel(); finishManagedJob(context, prepared.call, key, handle,
                    ProductManagedJobExecution(Result.Err(error), ExecutionUsage(), true, handle.operationId))
                return Result.Err(error)
            case Result.Ok(_) => () }
        emitJobEvent("started", snapshot)
        Result.Ok(reservation.launchResult())
    }

    private func runManagedJob(vnext: ProductVnextControl, context: ToolInvocationContext,
        call: ToolCall, key: ProductAsyncJobKey, handle: ProductManagedJobHandle): Unit {
        var admitted = false
        let outcome = try {
            var failure: ?AgentError = None
            while (true) {
                match (vnext.managedJobLaunchReady(handle.reservation)) {
                    case Result.Err(error) => failure = Some(error); break
                    case Result.Ok(true) => break
                    case Result.Ok(false) => sleep(Duration.millisecond * 5) }
            }
            match (failure) { case Some(error) => ProductManagedJobExecution(Result.Err(error), ExecutionUsage(), true, handle.operationId)
                case None => match (handle.reservation.claim()) {
                    case Result.Err(error) => ProductManagedJobExecution(Result.Err(error), ExecutionUsage(), true, handle.operationId)
                    case Result.Ok(admission) =>
                        handle.admission = Some(admission); admitted = true
                        let allowed = markManagedJobExecuting(key)
                        if (allowed.isError()) {
                            admission.cancel()
                            ProductManagedJobExecution(Result.Err(allowed.error().getOrThrow()), ExecutionUsage(), true, handle.operationId)
                        } else { vnext.executeManagedJob(admission, context, handle.budget, handle.operationId) }
                } }
        } catch (_: Exception) {
            handle.reservation.cancel()
            ProductManagedJobExecution(Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "task.managed_job_worker_unknown", "managed job worker requires reconciliation")),
                handle.budget.snapshot(), !admitted, handle.operationId)
        }
        finishManagedJob(context, call, key, handle, outcome)
    }

    private func markManagedJobExecuting(key: ProductAsyncJobKey): Result<Unit> {
        lock.lock()
        try {
            let job = findJobLocked(key).getOrThrow()
            if (closing || job.status != "running") { return taskError("task.managed_job_cancelled", "managed job was cancelled before execution") }
            job.executing = true; job.updatedAt = nowMillis()
            persistRootLocked(job.rootSessionId)
        } finally { lock.unlock() }
    }

    private func retryManagedCleanup(): Unit {
        let pending = ArrayList<(String, ProductManagedJobHandle)>()
        lock.lock()
        try { for ((id, handle) in managedJobs) {
            var recovering = false
            for (job in jobs where job.id == id && job.status == "recovery_required") { recovering = true }
            if (recovering) { pending.add((id, handle)) }
        } } finally { lock.unlock() }
        for ((id, handle) in pending) {
            let acknowledged = try { handle.acknowledged() } catch (_: Exception) { false }
            if (!acknowledged) { continue }
            lock.lock()
            try {
                managedJobs.remove(id)
                for (job in jobs where job.id == id && job.status == "recovery_required") {
                    if (job.executing) {
                        job.executing = false
                        job.updatedAt = nowMillis()
                        let _ = persistRootLocked(job.rootSessionId)
                    }
                }
            } finally { lock.unlock() }
            match (handle.admission) { case Some(value) => value.detachParentAfterCleanup(); case None => handle.reservation.detachUnclaimedParent() }
        }
    }

    private func settleManagedBudgetLocked(id: String, usage: ExecutionUsage): Result<Unit> {
        let lease = match (childBudgetLeases.get(id)) { case None => return Result.Ok(()); case Some(value) => value }
        childUsage[id] = usage
        let settled = lease.settle(usage)
        if (settled.isOk()) { childBudgetLeases.remove(id); childUsage.remove(id) }
        match (settled) { case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(()) }
    }

    private func finishManagedJob(context: ToolInvocationContext, call: ToolCall, key: ProductAsyncJobKey,
        handle: ProductManagedJobHandle, outcome: ProductManagedJobExecution): Unit {
        let snapshot: ProductAsyncJobSnapshot
        var notify = false
        let acknowledged = try { handle.acknowledged() } catch (_: Exception) { false }
        lock.lock()
        try {
            let job = findJobLocked(key).getOrThrow()
            if (!outcome.settled || !acknowledged) {
                job.status = "recovery_required"; job.error = "managed job has unsettled canonical execution or cleanup"
                // Do not refund or lose the actual cancellation/cleanup owner.
                job.executing = !acknowledged; childUsage[job.id] = outcome.usage
                if (acknowledged) {
                    // Unknown effect keeps the existing child budget reserved,
                    // while actual cleanup no longer occupies an OS owner.
                    managedJobs.remove(job.id)
                    match (handle.admission) { case Some(value) => value.detachParentAfterCleanup(); case None => handle.reservation.detachUnclaimedParent() }
                }
            } else {
                match (outcome.result) {
                    case Result.Ok(ToolInvocationResult.Completed(value)) =>
                        job.result = Some(taskPersistBoundJobResult(value.output)); job.status = if (value.isError) { "failed" } else { "completed" }
                        job.error = if (value.isError) { "managed job returned an error" } else { "" }
                    case Result.Err(error) =>
                        job.status = if (error.kind == AgentErrorKind.Cancelled || handle.reservation.cancellationToken.isCancelled()) { "cancelled" } else { "failed" }
                        job.error = error.code
                    case _ => job.status = "failed"; job.error = "managed job did not execute its frozen plan"
                }
                job.executing = false
                match (settleManagedBudgetLocked(job.id, outcome.usage)) {
                    case Result.Err(error) => job.status = "recovery_required"; job.error = error.code
                    case Result.Ok(_) =>
                        managedJobs.remove(job.id)
                        match (handle.admission) { case Some(value) => value.detachParentAfterCleanup(); case None => handle.reservation.detachUnclaimedParent() }
                }
            }
            job.updatedAt = nowMillis(); prepareJobSettlementLocked(job)
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Err(error) => markJobPersistenceRecoveryLocked(job, error)
                case Result.Ok(_) => notify = job.status != "recovery_required" }
            snapshot = job.snapshot()
        } finally { lock.unlock() }
        deliverBackgroundSnapshot(context, call, key, snapshot, notify)
    }

    private func deliverSubagentMessage196(
        context: ToolInvocationContext,
        to: String,
        message: String,
        replyTo: String,
        budgetAuthority!: ?ToolInvocationContext = None
    ): Result<Unit> {
        let deliveries = ArrayList<ProductHubMessageState>()
        lock.lock()
        try {
            let previousMessages = hubMessages.toArray()
            let previousMessageCounter = messageCounter
            let sender = hubIdentityLocked(context)
            let targets = hubTargetsLocked(sender, to)
            if (targets.isEmpty()) {
                return taskError<Unit>(
                    "hub.peer_not_found",
                    "unknown or unavailable hub peer: " + to
                )
            }
            for (target in targets) {
                if (target.id != "Main" && target.status != "running" && target.status != "blocked") {
                    let child = findSubagentLocked(target.id).getOrThrow()
                    if (!child.capabilityCeilingKnown) {
                        return taskError<Unit>("child.redelegation_required",
                            "restored child has no recorded capability ceiling; delegate a new task")
                    }
                }
                if (target.id == sender.id) {
                    return taskError<Unit>(
                        "hub.self_send",
                        "hub cannot send a message to the caller"
                    )
                }
                messageCounter += 1
                let snapshot = ProductHubMessageSnapshot(
                    "message-" + nowMillis().toString() + "-" + messageCounter.toString(),
                    sender.id,
                    target.id,
                    message,
                    replyTo,
                    nowMillis()
                )
                let state = ProductHubMessageState(
                    snapshot,
                    target.sessionId,
                    sender.rootSessionId,
                    waitCallId: if (target.id == "Main" && sender.id != "Main") {
                        sender.parentToolCallId
                    } else {
                        ""
                    },
                    reviveTarget: target.id != "Main" && target.status != "running" && target.status != "blocked"
                )
                hubMessages.add(state)
                deliveries.add(state)
            }
            pruneHubMessagesLocked()
            match (persistRootLocked(sender.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    hubMessages.clear()
                    hubMessages.add(all: previousMessages)
                    messageCounter = previousMessageCounter
                    rememberTaskPersistenceFailureLocked(sender.rootSessionId, error)
                    return Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (delivery in deliveries) {
            if (delivery.reviveTarget) {
                match (startOwnedWorker({ =>
                    reviveSubagent(delivery.snapshot.to, delivery.snapshot,
                        match (budgetAuthority) { case Some(value) => value; case None => context })
                })) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
            } else {
                if (delivery.waitCallId != "") {
                    // The target parent still has the task ToolCall pending.
                    // Keep the already-durable Hub message queued; the task
                    // executor's persisted-result hook delivers it after the
                    // paired canonical ToolResult closes that protocol round.
                    continue
                }
                match (runtime.appendExternalMessageOnce(
                    delivery.targetSessionId,
                    "hub-delivery:" + delivery.snapshot.id,
                    hubMessageModelMessage(delivery.snapshot),
                    source: "hub_delivery"
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        }
        Result<Unit>.Ok(())
    }

    func deliverHubMessagesAfterParentResult(
        sessionId: SessionId,
        parentToolCallId: String
    ): Result<Unit> {
        let pending = ArrayList<ProductHubMessageState>()
        lock.lock()
        try {
            for (state in hubMessages where
                state.targetSessionId.value == sessionId.value &&
                state.waitCallId == parentToolCallId) {
                pending.add(state)
            }
        } finally {
            lock.unlock()
        }
        if (pending.isEmpty()) { return Result.Ok(()) }
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (message in pending) {
            match (runtime.appendExternalMessageOnce(
                sessionId,
                "hub-delivery:" + message.snapshot.id,
                match(message.deliveryText111){
                    case Some(text)=>ModelMessage(ModelRole.User,[ModelBlock(ModelBlockKind.Text,text:text)])
                    case None=>hubMessageModelMessage(message.snapshot)},
                source: "hub_delivery"
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }




    public func waitForJobs(
        sessionId: SessionId,
        ids: Array<String>,
        timeoutMillis: Int64
    ): Array<ProductAsyncJobSnapshot> {
        let keys = selectJobKeys(sessionId, ids)
        let started = nowMillis()
        while (true) {
            let selection = jobSelectionByKeys(keys)
            if (selection.snapshots.isEmpty() || selection.settledAndDelivered ||
                (timeoutMillis > 0 && nowMillis() - started >=
                timeoutMillis)) {
                return selection.snapshots
            }
            sleep(Duration.millisecond * 10)
        }
        []
    }

    public func cancelJobs(
        sessionId: SessionId,
        ids: Array<String>
    ): Array<ProductAsyncJobSnapshot> {
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(_) => return []
        }
        let keys = ArrayList<ProductAsyncJobKey>()
        lock.lock()
        try {
            for (job in jobs where job.sessionId.value == sessionId.value && containsTaskString(ids, job.id)) {
                keys.add(job.key())
            }
        } finally {
            lock.unlock()
        }
        cancelJobKeys(runtime, keys.toArray())
        jobSelectionByKeys(keys.toArray()).snapshots
    }

    // Only this actual canonical hidden cancel uses the paid opt-in. Legacy
    // cancelJobs and lifecycle callers retain their original default path.
    func cancelPluginJobs172(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let runtime = match (attachedProduct()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let meter = admission.createJobSnapshotMeter165()
        try { cancelPluginJobsHelper172(runtime, context, request, admission, meter) }
        finally { meter.closeUnpublished151() }
    }
    private func cancelPluginJobsHelper172(runtime: ProductRuntime, context: ToolInvocationContext,
        request: AgentValue, admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151): Result<ToolResult> {
        // This fixed cell and every captured key are paid before construction.
        meter.fundAdditional151(8192, 16)
        let capture = ProductJobCancelCapture172(admission, meter)
        let fence = match (admission.acquireJobCancelCapture172()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let keys = try { capturePluginJobKeys166(context, request, meter) } finally { fence.close() }
        let actual = match (keys) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        cancelJobKeys(runtime, actual, paidCapture172: Some(capture))
        // Every SQL/cancellation Err was copied while its original frame was
        // still alive. Its actual installed owner remains reachable and paid;
        // returning an Err or a cancellation request does not ACK that data.
        match (capture.failure) { case Some(error) => return Result.Err(error); case None => () }
        let observation = match (admission.acquireJobCancelEffect172()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try { observePluginJobKeys166(context, actual, admission, meter) }
        finally { observation.close() }
    }
    private func fundJobCancelTargetsLocked172(keys: Array<ProductAsyncJobKey>, capture: ProductJobCancelCapture172): Unit {
        let invoice = ProductJobSnapshotInvoice165()
        for (key in keys) {
            match (findJobLocked(key)) { case Some(job) =>
                // The exact same lock protects this invoice, snapshot and state
                // mutation. Result/error Strings and every retained occurrence
                // are paid, including aliases retained by ordinary job sinks.
                let size = job.id.size + job.agentId.size + job.jobType.size + job.status.size +
                    job.label.size + job.error.size + job.rootSessionId.value.size + job.sessionId.value.size +
                    job.ownerRunId.value.size + job.operationId.size
                if (size > (Int64.Max-8192)/8) { throw LogicalJsonPayloadError("cancel snapshot invoice overflow") }
                invoice.add(size*8+8192, 48)
                match (job.result) { case Some(value) =>
                    let measured = capture.meter.measureBorrowedValue151(value)
                    invoice.add(measured.bytes, measured.nodes)
                    case None => () }
                case None => () }
        }
        capture.meter.fundAdditional151(invoice.bytes, invoice.nodes)
        if (invoice.bytes > (Int64.Max-4096)/16 || invoice.nodes > (Int64.Max-4096-invoice.bytes*16)/512) {
            throw LogicalJsonPayloadError("cancel retained SUM overflow") }
        // Ordinary callback APIs have no alias retirement receipt. Keep this
        // real installed share paid rather than refund on callback return.
        capture.admission.retainWorkerMetadata111(max(16384, invoice.bytes*16+invoice.nodes*512+4096))
    }


    private func jobCancelObserved172<T>(result: Result<T>, capture: ?ProductJobCancelCapture172): Unit {
        match (result) { case Result.Err(error) => match(capture){case Some(value)=>value.capture(error);case None=>()}; case Result.Ok(_)=>() }
    }
    private func cancelJobKeys(
        runtime: ProductRuntime,
        keys: Array<ProductAsyncJobKey>,
        paidCapture172!: ?ProductJobCancelCapture172 = None<ProductJobCancelCapture172>
    ): Unit {
        let effect172 = match (paidCapture172) { case Some(capture) =>
            match (capture.admission.acquireJobCancelEffect172()) { case Result.Ok(value) => Some(value)
                case Result.Err(error) => capture.capture(error); return }
            case None => None<ToolExecutionHandoffLease> }
        lock.lock()
        let targets = try {
            match (paidCapture172) { case Some(capture) => fundJobCancelTargetsLocked172(keys,capture); case None => () }
            ArrayList<ProductAsyncJobTarget>()
        } catch (error: Exception) { lock.unlock(); match(effect172){case Some(value)=>value.close();case None=>()}; throw error }
        try {
            for (key in keys) {
                match (findJobLocked(key)) {
                    case Some(job) =>
                        if (job.status == "running") {
                            let pluginChild = match (findSubagentLocked(job.agentId)) {
                                case Some(value) => value.pluginAdmission111.isSome(); case None => false }
                            if (job.jobType == "managed" || pluginChild) {
                                // This is a request, not a command outcome. The
                                // actual worker settles its Receipt/Task once.
                                job.error = "cancellation_requested"
                            } else {
                                job.status = "cancelled"
                                job.error = "cancelled by hub"
                                prepareJobSettlementLocked(job)
                            }
                            job.updatedAt = nowMillis()
                        }
                        targets.add(ProductAsyncJobTarget(key, job.snapshot()))
                    case None => ()
                }
            }
            match (persistAllTaskRootsLocked()) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    match(paidCapture172){case Some(capture)=>capture.capture(error);case None=>()}
                    for (key in keys) {
                        match (findJobLocked(key)) {
                            case Some(job) => markJobPersistenceRecoveryLocked(job, error)
                            case None => ()
                        }
                    }
                    targets.clear()
            }
        } finally {
            lock.unlock()
            match(effect172){case Some(value)=>value.close();case None=>()}
        }
        for (target in targets) {
            let snapshot = target.snapshot
            if (snapshot.jobType == "managed") {
                if (snapshot.status == "running") {
                    let handle = { => lock.lock(); try { managedJobs.get(snapshot.id) } finally { lock.unlock() } }()
                    match (handle) { case Some(value) => value.reservation.cancel(); case None => () }
                    emitJobEvent("cancellation_requested", snapshot,paidCapture172:paidCapture172)
                }
                continue
            }
            let pluginChild = { => lock.lock(); try {
                match (findSubagentLocked(snapshot.agentId)) {
                    case Some(value) => value.pluginAdmission111.isSome(); case None => false }
            } finally { lock.unlock() } }()
            if (pluginChild) {
                match (lockAndFindSubagent(target.key.rootSessionId, snapshot.agentId, "")) {
                    case Some(child) => jobCancelObserved172(cancelPluginChild111(runtime, child.id),paidCapture172)
                    case None => () }
                continue
            }
            if (snapshot.status != "cancelled") { continue }
            // Historical legacy Bash records remain descriptive. There is no
            // live old process owner to recover or cancel by a persisted id.
            if (snapshot.jobType != "bash") {
                let child = lockAndFindSubagent(target.key.rootSessionId, snapshot.agentId, "")
                match (child) {
                    case Some(childSnapshot) =>
                        jobCancelObserved172(runtime.client.cancel(childSnapshot.runId),paidCapture172)
                        let _ = tasks.transition(
                            TaskId(childSnapshot.id),
                            TaskStatus.Cancelled
                        )
                        if (subagentStatus(childSnapshot.id) != "cancelled") {
                            let _ = finishSubagent(
                                childSnapshot.id,
                                "cancelled"
                            )
                        }
                    case None => ()
                }
            }
            emitJobEvent("cancelled", snapshot,paidCapture172:paidCapture172)
            injectJobSettlement(target.key, waitForParent: true)
        }
    }



    // Scalar data from the already-owned result slot. Pure preparation is
    // not admission; the actual write below rechecks current private custody.
    func observePluginResultSlot150(context: ToolInvocationContext,
        consume: (Bool, Int64, Bool) -> Unit): Result<Unit> {
        lock.lock()
        try {
            if (closing) { return taskError("child.owner_closed", "child runtime is closing") }
            match (findYieldLocked(context.runId)) {
                case None => consume(false, -1, false)
                case Some(state) => consume(true, state.revision150, state.error != "") }
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    // Generic mutation of an existing child result slot, never a child start,
    // business Yield parser, canonical finalizer, or budget/physical ACK.
    func writePluginResultSlot150(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        if (!pluginChildResultWriteInputValid150(request)) {
            return taskError("child.result_write_invalid", "invalid frozen result write data") }
        let input = match (admission.retainResultWriteInput150()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        // This same installed bank pays new slot/container aliases before any
        // mutation. All retained raw DATA remains funded until actual retirement.
        admission.retainWorkerMetadata111(16384)
        let lease = match (admission.acquireResultWriteLease150()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let output: AgentValue
        try {
            lock.lock()
            try {
                if (closing || admission.cancellation.isCancelled()) {
                    return taskError("child.owner_closed", "child result owner is closing or cancelled") }
                let state = findYieldLocked(context.runId)
                let available = input.field("available").getOrThrow().asBool()
                let revision = Int64.parse(input.field("revision").getOrThrow().asNumberText())
                if (available != state.isSome() || (state.isSome() && state.getOrThrow().revision150 != revision)) {
                    return taskError("child.result_slot_changed", "result slot changed after pure preparation") }
                let mutation = input.field("mutation").getOrThrow()
                let kind = httpIntentText(mutation, "kind")
                if (available) {
                    // Only the private live record for THIS child Run/session,
                    // actual physical worker and original reserved child budget
                    // can own the slot. A decoded observation is insufficient.
                    var found = false
                    for (record in records where record.runId.value == context.runId.value) {
                        if (found || record.sessionId.value != context.sessionId.value ||
                            record.status != "running" || !record.executionInProgress || record.finishing ||
                            record.pluginCancellationRequested111 || childBudgetLeases.get(record.id).isNone() ||
                            record.budgetAuthority.isNone()) {
                            return taskError("child.result_owner_changed", "result slot lost its actual running child custody") }
                        found = true
                    }
                    if (!found) { return taskError("child.result_owner_changed", "actual running child owner is absent") }
                    if (kind != "none") {
                        let target = state.getOrThrow()
                        if (target.revision150 == Int64.Max) {
                            return taskError("child.result_revision_exhausted", "result slot revision cannot advance") }
                        let value = mutation.field("value").getOrThrow()
                        match (kind) {
                            case "replace_error" => target.error = value.text
                            case "replace_terminal" => target.terminal = Some(value)
                            case "append_section" => target.sections.add(ProductYieldSection(
                                mutation.field("labels").getOrThrow().items.toArray().map { label => label.text }, value))
                            case "use_last_turn" => target.useLastTurn = true
                            case _ => return taskError("child.result_write_invalid", "unsupported frozen slot mutation") }
                        target.revision150 += 1
                    }
                }
                // Known business errors are DATA inside a successful primitive
                // receipt. Native restores the original outer ToolResult error.
                output = input.field("result").getOrThrow()
            } finally { lock.unlock() }
        } finally { lease.close() }
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(ToolResult(admission.callId, output))
    }

    public func cancel(parentRunId: RunId): Result<Unit> {
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let targets = ArrayList<ProductSubagentSnapshot>()
        let jobTargets = ArrayList<ProductAsyncJobKey>()
        lock.lock()
        try {
            for (record in records where record.budgetParentRunId.value == parentRunId.value && (record.status == "running" ||
                record.status == "blocked")) {
                targets.add(record.snapshot())
            }
            for (job in jobs where job.ownerRunId.value == parentRunId.value && job.status == "running") {
                jobTargets.add(job.key())
            }
        } finally {
            lock.unlock()
        }
        var firstError: ?AgentError = None
        for (target in targets) {
            if (isPluginChild111(target.id)) {
                match (cancelPluginChild111(runtime, target.id)) {
                    case Result.Err(error) => if (firstError.isNone()) { firstError = Some(error) }
                    case Result.Ok(_) => () }
                continue
            }
            match (runtime.client.cancel(target.runId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    if (firstError.isNone()) {
                        firstError = Some(error)
                    }
            }
            let _ = tasks.transition(
                TaskId(target.id),
                TaskStatus.Cancelled
            )
            if (subagentStatus(target.id) != "cancelled") {
                let _ = finishSubagent(target.id, "cancelled")
            }
        }
        cancelJobKeys(runtime, jobTargets.toArray())
        match (firstError) {
            case Some(error) => Result.Err(error)
            case None => Result.Ok(())
        }
    }

    // One actual child per frozen intent. Background return is gated by the
    // original Core admission notification, never by merely queuing a worker.
    func startPluginChild111(context: ToolInvocationContext, value: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        let data = try { ProductPluginChildRequest111(value) } catch (_: Exception) {
            return taskError("child.request_invalid", "invalid frozen child request") }
        // The existing operator switch may run a background-requested role inline.
        let background = data.background && asyncEnabled
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let runtime = match (attachedProduct()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
        let model = if (data.modelAlias == "") { parentModel(runtime, context.sessionId) } else { data.modelAlias }
        let base = match (runtime.prepareRequest(data.prompt, modelOverride: model, thinking: data.thinking, inheritedModelSettings180: Some(context.modelSettingsDescriptor180()))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
        let capabilities = effectiveChildCapabilities(context.capabilities, data.ceiling, context.capabilities)
        let child = productPluginChildRequest111(base, data, capabilities, context.budget)
        let depth = depthForRun(context.runId) + 1
        if (depth > child.budget.maxDepth) { return taskError("subagent.budget_exceeded", "subagent resource budget exceeded") }
        let state = match (createPluginChild111(runtime, context, data, child, depth, admission)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
        match (reserveChildBudget(context, state.id, executionBudgetFrom(child.budget))) {
            case Result.Err(error) =>
                let _ = finishSubagent(state.id, "failed", error: error.message); releaseChildExecution(state.id)
                return Result.Err(error)
            case Result.Ok(_) => () }
        match (tasks.create(TaskId(state.id), data.prompt)) {
            case Result.Err(error) =>
                let _ = finishSubagent(state.id, "failed", error: error.message); releaseChildExecution(state.id)
                return Result.Err(error)
            case Result.Ok(_) => () }
        let _ = tasks.transition(TaskId(state.id), TaskStatus.Running, runId: Some(child.runId))
        if (background) { match (createPluginChildJob111(context, state)) {
            case Result.Err(error) =>
                let _ = finishSubagent(state.id, "failed", error: error.message); releaseChildExecution(state.id)
                return Result.Err(error)
            case Result.Ok(_) => () } }
        let worker = match (startPluginWorker111<ToolResult>(state,
            { => { => runPluginChild111(runtime, state.id, child, admission) } })) {
            case Result.Err(error) =>
                let _ = finishSubagent(state.id, "failed", error: error.message); releaseChildExecution(state.id)
                return Result.Err(error)
            case Result.Ok(value) => value }
        if (!background && !data.admissionOnly) { return worker.collect() }
        while (true) {
            match (context.cancellation.check()) {
                case Result.Err(error) => let _ = runtime.client.cancel(child.runId); return Result.Err(error)
                case Result.Ok(_) => () }
            lock.lock()
            try {
                let actual = findSubagentLocked(state.id).getOrThrow()
                if (actual.pluginStartAdmitted111) { return pluginLaunchResultLocked111(actual, admission.callId) }
                if (pluginWorkersReturnedLocked111(actual)) {
                    return taskError("child.start_not_admitted", if (actual.error != "") { actual.error } else { "child returned without actual Run admission" }) }
                if (closing || actual.status == "cancelled") {
                    return taskError("child.cancelled_before_launch", "child custody was cancelled before actual Run admission") }
            } finally { lock.unlock() }
            sleep(Duration.millisecond * 5)
        }
        taskError("child.start_not_admitted", "child has no completed admission")
    }

    // Generic actual peer-membership facts only. The Native caller owns Hub
    // op names, Main/sub presentation and legacy output assembly.
    // Original cleanup observes existing physical ACKs outside all new gates;
    // it never treats the Native observation/result as worker retirement.
    func observePluginJobs165(context: ToolInvocationContext, admission: HostPluginChildAdmission111): Result<ToolResult> {
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        retryManagedCleanup(); retryPluginChildCompletions111()
        let lease = match (admission.acquireJobSnapshotLease165()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let result = try {
            let meter = admission.createJobSnapshotMeter165()
            try { observePluginJobsFrame165(context, admission, meter) }
            finally { meter.closeUnpublished151() }
        } finally { lease.close() }
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        result
    }
    private func observePluginJobsFrame165(context: ToolInvocationContext, admission: HostPluginChildAdmission111,
        meter: HostPaidValueProjection151): Result<ToolResult> {
        // Counter and all result measurement frames retire before meter.close.
        meter.fundAdditional151(4096, 8)
        let invoice = ProductJobSnapshotInvoice165()
        lock.lock()
        try {
            if (closing) { return taskError("peer.owner_closed", "peer owner is closing") }
            let root = hubIdentityLocked(context).rootSessionId.value
            for (job in jobs where job.sessionId.value == context.sessionId.value) {
                let header = job.id.size + job.agentId.size + job.jobType.size + job.status.size + job.label.size + job.error.size
                if (header > (Int64.Max - 1024) / 6) { return taskError("job.observation_size_invalid", "job snapshot invoice overflow") }
                invoice.add(header * 6 + 1024, 24)
                match (job.result) {
                    case Some(value) =>
                        let shape = meter.measureBorrowedValue151(value)
                        invoice.add(shape.bytes, shape.nodes)
                    case None => () }
            }
            for (warning in recoveryWarnings where warning.rootSessionId == root || warning.rootSessionId == "unknown") {
                let bytes = warning.rootSessionId.size + warning.file.size + warning.reason.size
                if (bytes > (Int64.Max - 512) / 6) { return taskError("job.observation_size_invalid", "warning invoice overflow") }
                invoice.add(bytes * 6 + 512, 2)
            }
            let output = admission.retainObservation(invoice.bytes, invoice.nodes, { =>
                let values = ArrayList<AgentValue>()
                for (job in jobs where job.sessionId.value == context.sessionId.value) {
                    values.add(objectValue([ValueField("id",textValue(job.id)),ValueField("agent_id",textValue(job.agentId)),
                        ValueField("type",textValue(job.jobType)),ValueField("status",textValue(job.status)),
                        ValueField("label",textValue(job.label)),ValueField("duration_ms",integerValue(max(0,job.updatedAt-job.startedAt))),
                        ValueField("has_result",boolValue(job.result.isSome())),ValueField("result",job.result ?? nullValue()),
                        ValueField("error",textValue(job.error))]))
                }
                let warnings = ArrayList<AgentValue>()
                for (warning in recoveryWarnings where warning.rootSessionId == root || warning.rootSessionId == "unknown") {
                    warnings.add(textValue(warning.text())) }
                objectValue([ValueField("schema",textValue("axyndra.job-observation/v1")),
                    ValueField("jobs",listValue(values.toArray())),ValueField("recovery_warnings",listValue(warnings.toArray()))])
            })
            Result.Ok(ToolResult(admission.callId, output))
        } finally { lock.unlock() }
    }
    // Native owns the Hub parser and wait output. This Kernel primitive only
    // waits on exact original job incarnations/physical settlement witnesses.
    func waitPluginJobs166(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        retryManagedCleanup(); retryPluginChildCompletions111()
        let meter = admission.createJobSnapshotMeter165()
        try { waitPluginJobsFrame166(context,request,admission,meter) }
        finally { meter.closeUnpublished151() }
    }
    private func waitPluginJobsFrame166(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151): Result<ToolResult> {
        // Before creating arrays, keys, counters, or indexed-reader wrappers.
        meter.fundAdditional151(4096,8)
        let capture = match (admission.acquireJobWaitCapture166()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let keys = try { capturePluginJobKeys166(context,request,meter) } finally { capture.close() }
        let selected = match (keys) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let timeout = Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText())
        // Original deadline starts after exact job-generation selection.
        let started = nowMillis()
        while (true) {
            // Full actual Root/operation/binding/configuration checks outside
            // Task/Registry locks. Cancellation is never physical retirement.
            match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            retryManagedCleanup(); retryPluginChildCompletions111()
            let ready = pluginJobWaitReady166(selected)
            if (ready || (timeout > 0 && nowMillis()-started >= timeout)) {
                let fence = match (admission.acquireJobWaitObservation166()) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let output = try { observePluginJobKeys166(context,selected,admission,meter) } finally { fence.close() }
                match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                return output
            }
            // timeout=0 remains unbounded. The ordinary Native watchdog has
            // not started; it cannot replace this existing Kernel wait.
            sleep(Duration.millisecond*10)
        }
        taskError("job.wait_unknown","actual waiting frame did not return")
    }
    private func capturePluginJobKeys166(context: ToolInvocationContext, request: AgentValue,
        meter: HostPaidValueProjection151): Result<Array<ProductAsyncJobKey>> {
        let ids = request.field("ids").getOrThrow().asArray()
        lock.lock()
        try {
            if (closing) { return taskError("peer.owner_closed","job owner is closing") }
            // Invoice every newly retained key/node/String occurrence BEFORE
            // allocating its array. Input IDs themselves remain original loans.
            var bytes: Int64 = 4096; var count: Int64 = 8
            for (job in jobs where job.sessionId.value == context.sessionId.value && jobIdSelected166(ids,job.id)) {
                let size = job.rootSessionId.value.size+job.sessionId.value.size+job.id.size
                if (size > (Int64.Max-1024)/6 || bytes > Int64.Max-(size*6+1024) || count > Int64.Max-8) {
                    return taskError("job.wait_size_invalid","job key invoice overflow") }
                bytes += size*6+1024; count += 8
            }
            meter.fundAdditional151(bytes,count)
            let result = ArrayList<ProductAsyncJobKey>()
            for (job in jobs where job.sessionId.value == context.sessionId.value && jobIdSelected166(ids,job.id)) {
                result.add(job.key()) }
            Result.Ok(result.toArray())
        } finally { lock.unlock() }
    }
    private func jobIdSelected166(ids: JsonArray, id: String): Bool {
        if (ids.size()==0) { return true }
        for (index in 0..ids.size()) { if (ids.get(index).getOrThrow().text==id) { return true } }
        false
    }
    private func pluginJobWaitReady166(keys: Array<ProductAsyncJobKey>): Bool {
        lock.lock()
        try {
            if (closing) { return true }
            var present: Int64 = 0
            for (key in keys) {
                match (findJobLocked(key)) { case Some(job) =>
                    present += 1
                    if (job.status!="running" && job.settlementInjected && pluginJobPhysicalReturnedLocked111(job)) { return true }
                    case None => () }
            }
            // The original wait returns on ANY delivered settled job, or when
            // every captured original incarnation disappeared. Never all-only.
            present==0
        } finally { lock.unlock() }
    }
    private func observePluginJobKeys166(context: ToolInvocationContext, keys: Array<ProductAsyncJobKey>,
        admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151): Result<ToolResult> {
        meter.fundAdditional151(4096,8); let invoice=ProductJobSnapshotInvoice165()
        lock.lock()
        try {
            if (closing) { return taskError("peer.owner_closed","job owner is closing") }
            let root=hubIdentityLocked(context).rootSessionId.value
            for (key in keys) { match (findJobLocked(key)) { case Some(job) =>
                let size=job.id.size+job.agentId.size+job.jobType.size+job.status.size+job.label.size+job.error.size
                if(size>(Int64.Max-1024)/6){return taskError("job.observation_size_invalid","job snapshot invoice overflow")}
                invoice.add(size*6+1024,24)
                match(job.result){case Some(value)=>let shape=meter.measureBorrowedValue151(value);invoice.add(shape.bytes,shape.nodes);case None=>()}
                case None=>() } }
            for (warning in recoveryWarnings where warning.rootSessionId==root || warning.rootSessionId=="unknown") {
                let size=warning.rootSessionId.size+warning.file.size+warning.reason.size
                if(size>(Int64.Max-512)/6){return taskError("job.observation_size_invalid","warning invoice overflow")}
                invoice.add(size*6+512,2) }
            let output=admission.retainObservation(invoice.bytes,invoice.nodes,{=>
                let values=ArrayList<AgentValue>()
                for(key in keys){match(findJobLocked(key)){case Some(job)=>values.add(objectValue([
                    ValueField("id",textValue(job.id)),ValueField("agent_id",textValue(job.agentId)),ValueField("type",textValue(job.jobType)),
                    ValueField("status",textValue(job.status)),ValueField("label",textValue(job.label)),
                    ValueField("duration_ms",integerValue(max(0,job.updatedAt-job.startedAt))),ValueField("has_result",boolValue(job.result.isSome())),
                    ValueField("result",job.result ?? nullValue()),ValueField("error",textValue(job.error))]));case None=>()}}
                let warnings=ArrayList<AgentValue>()
                for(warning in recoveryWarnings where warning.rootSessionId==root || warning.rootSessionId=="unknown"){warnings.add(textValue(warning.text()))}
                objectValue([ValueField("schema",textValue("axyndra.job-observation/v1")),ValueField("jobs",listValue(values.toArray())),
                    ValueField("recovery_warnings",listValue(warnings.toArray()))])})
            Result.Ok(ToolResult(admission.callId,output))
        } finally {lock.unlock()}
    }
    func observePluginPeers111(context: ToolInvocationContext, admission: HostPluginChildAdmission111): Result<ToolResult> {
        match(admission.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        try {
            if(closing){return taskError("peer.owner_closed","peer owner is closing")}
            let caller=hubIdentityLocked(context)
            var encodedCeiling:Int64=512
            var nodeCeiling:Int64=16
            for(record in records where record.parentSessionId.value==caller.rootSessionId.value){
                let bytes=record.id.size+record.agent.size+record.status.size+record.currentTool.size
                if(bytes>Int64.Max/12 || encodedCeiling>Int64.Max-(bytes*6+256) || nodeCeiling>Int64.Max-12){
                    return taskError("peer.observation_size_invalid","peer snapshot invoice overflow")}
                encodedCeiling+=bytes*6+256
                nodeCeiling+=12
            }
            let output=admission.retainObservation(encodedCeiling,nodeCeiling,{=>
                let values=ArrayList<AgentValue>()
                for(record in records where record.parentSessionId.value==caller.rootSessionId.value){
                    values.add(objectValue([ValueField("id",textValue(record.id)),ValueField("label",textValue(record.agent)),
                        ValueField("status",textValue(record.status)),ValueField("activity",textValue(record.currentTool))]))
                }
                objectValue([ValueField("schema",textValue("axyndra.peer-observation/v1")),
                    ValueField("caller_is_root",boolValue(caller.id=="Main")),ValueField("members",listValue(values.toArray()))])
            })
            Result.Ok(ToolResult(admission.callId,output))
        } finally {lock.unlock()}
    }

    // Transport state only: actual caller's already-durable mailbox, optional
    // consumption and original Task snapshot transaction. No Hub grammar or
    // presentation is evaluated here; those belong to the installed package.
    // A single actual canonical mailbox wait. The installed Native package
    // owns Hub syntax/presentation; this owner only selects original mailbox
    // data and persists the same consumption transaction as the old wait.
    func waitPluginPeers171(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let meter = admission.createJobSnapshotMeter165()
        try { waitPluginPeerFrame171(context, request, admission, meter) }
        finally { meter.closeUnpublished151() }
    }
    private func waitPluginPeerFrame171(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151): Result<ToolResult> {
        // Fixed wrappers are paid before reader/identity/optional result cells.
        // All dynamic mailbox copies below use the same installed reservation.
        meter.fundAdditional151(8192, 16)
        let first = ProductPeerWaitSelection171()
        let sender = request.field("sender").getOrThrow().text
        let timeout = Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText())
        let capture = match (admission.acquirePeerWaitCapture171()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let identity = try {
            lock.lock()
            try {
                if (closing) { return taskError("peer.owner_closed", "mailbox owner is closing") }
                let caller = hubIdentityLocked(context)
                meter.fundAdditional151((caller.id.size + caller.rootSessionId.value.size) * 6 + 4096, 8)
                caller
            } finally { lock.unlock() }
        } finally { capture.close() }
        let started = nowMillis()
        while (true) {
            // Cancellation/revocation/source checks are not delivery or a
            // physical completion. No Task/Registry lock spans this sleep.
            match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (admission.acquirePeerWaitObservation171()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let output = try {
                observePluginPeerWait171(context, sender, identity.id, identity.rootSessionId,
                    timeout > 0 && nowMillis() - started >= timeout, admission, meter, first)
            } finally { fence.close() }
            let actual = match (output) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            match (actual) {
                case Some(value) =>
                    match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    return Result.Ok(value)
                case None => () }
            // Original zero timeout stays unbounded, before the ordinary
            // Native invocation watchdog begins. The controller owns Future.
            sleep(Duration.millisecond * 10)
        }
        taskError("peer.wait_unknown", "actual mailbox wait did not return")
    }
    private func observePluginPeerWait171(context: ToolInvocationContext, sender: String,
        callerId: String, rootSession: SessionId, timedOut: Bool,
        admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151,
        first: ProductPeerWaitSelection171): Result<?ToolResult> {
        lock.lock()
        try {
            if (closing) { return taskError("peer.owner_closed", "mailbox owner is closing") }
            let caller = hubIdentityLocked(context)
            if (caller.id != callerId || caller.rootSessionId.value != rootSession.value) {
                return taskError("peer.wait_identity_changed", "mailbox wait lost its original caller identity") }
            var count: Int64 = 0
            var bytes: Int64 = 4096
            first.value = None<ProductHubMessageState>
            for (state in hubMessages where !state.consumed && state.snapshot.to == callerId &&
                state.rootSessionId.value == rootSession.value && state.snapshot.from == sender) {
                let m = state.snapshot
                // Scalar borrowed lengths only: no temporary fields Array,
                // backing snapshot or cumulative invoice on an empty poll.
                if (m.id.size > (Int64.Max - 4096) / 6 || bytes > Int64.Max - m.id.size * 6 - 4096) {
                    return taskError("peer.observation_size_invalid", "mailbox wait invoice overflow") }
                bytes += m.id.size * 6 + 4096
                if (m.from.size > (Int64.Max - 4096) / 6 || bytes > Int64.Max - m.from.size * 6 - 4096) {
                    return taskError("peer.observation_size_invalid", "mailbox wait invoice overflow") }
                bytes += m.from.size * 6 + 4096
                if (m.to.size > (Int64.Max - 4096) / 6 || bytes > Int64.Max - m.to.size * 6 - 4096) {
                    return taskError("peer.observation_size_invalid", "mailbox wait invoice overflow") }
                bytes += m.to.size * 6 + 4096
                if (m.message.size > (Int64.Max - 4096) / 6 || bytes > Int64.Max - m.message.size * 6 - 4096) {
                    return taskError("peer.observation_size_invalid", "mailbox wait invoice overflow") }
                bytes += m.message.size * 6 + 4096
                if (m.replyTo.size > (Int64.Max - 4096) / 6 || bytes > Int64.Max - m.replyTo.size * 6 - 4096) {
                    return taskError("peer.observation_size_invalid", "mailbox wait invoice overflow") }
                bytes += m.replyTo.size * 6 + 4096
                if (count == Int64.Max) { return taskError("peer.observation_size_invalid", "mailbox count overflow") }
                count += 1
                if (first.value.isNone()) { first.value = Some(state) }
            }
            if (count == 0 && !timedOut) { return Result<?ToolResult>.Ok(None<ToolResult>) }
            if (count > (Int64.Max - 16) / 16) {
                return taskError("peer.observation_size_invalid", "mailbox node invoice overflow") }
            // Count, payment and actual backing construction share this lock.
            // An arriving message cannot enlarge an already-invoiced snapshot.
            meter.fundAdditional151(bytes, count * 16 + 16)
            let output = admission.retainObservation(bytes, count * 16 + 16, { =>
                let waited = match (first.value) {
                    case Some(state) =>
                        let m = state.snapshot
                        objectValue([ValueField("id", textValue(m.id)), ValueField("sender", textValue(m.from)),
                            ValueField("recipient", textValue(m.to)), ValueField("body", textValue(m.message)),
                            ValueField("reply_to", textValue(m.replyTo)), ValueField("created_at", integerValue(m.createdAt))])
                    case None => nullValue() }
                objectValue([ValueField("schema", textValue("axyndra.peer-wait-observation/v1")), ValueField("waited", waited)])
            })
            // Preserve original waitForHubMessage semantics: all matching
            // messages are consumed atomically, the first is presented. A SQL
            // failure restores every exact original state, not a replacement.
            if (count > 0) {
                let consumed = ArrayList<ProductHubMessageState>()
                // Finish all fallible backing construction before mutating
                // any original message. Paid capacity is not proof that an
                // actual allocation cannot throw.
                for (state in hubMessages where !state.consumed && state.snapshot.to == callerId &&
                    state.rootSessionId.value == rootSession.value && state.snapshot.from == sender) {
                    consumed.add(state) }
                for (state in consumed) { state.consumed = true }
                let saved = try { persistRootLocked(rootSession) }
                    catch (error: Exception) {
                        for (state in consumed) { state.consumed = false }; throw error }
                match (saved) {
                    case Result.Err(error) =>
                        for (state in consumed) { state.consumed = false }
                        rememberTaskPersistenceFailureLocked(rootSession, error)
                        return Result.Err(error)
                    case Result.Ok(_) => () }
            }
            Result<?ToolResult>.Ok(Some(ToolResult(admission.callId, output)))
        } finally { lock.unlock() }
    }

    func receivePluginPeers111(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        let lease=match(admission.acquireReceiveLease()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try {
            lock.lock()
            try {
                if(closing){return taskError("peer.owner_closed","peer owner is closing")}
                let caller=hubIdentityLocked(context)
                let peek=request.field("peek").getOrThrow().asBool()
                var encodedCeiling:Int64=512
                var nodeCeiling:Int64=16
                for(state in hubMessages where !state.consumed && state.snapshot.to==caller.id &&
                    state.rootSessionId.value==caller.rootSessionId.value){
                    let m=state.snapshot
                    var bytes:Int64=0
                    for(value in [m.id,m.from,m.to,m.message,m.replyTo]){
                        if(bytes>Int64.Max-value.size){return taskError("peer.observation_size_invalid","mailbox invoice overflow")}
                        bytes+=value.size
                    }
                    if(bytes>Int64.Max/12 || encodedCeiling>Int64.Max-(bytes*6+512) || nodeCeiling>Int64.Max-16){
                        return taskError("peer.observation_size_invalid","mailbox invoice overflow")}
                    encodedCeiling+=bytes*6+512;nodeCeiling+=16
                }
                // The same installed allocation pays all original fields and
                // independent snapshot codec occurrences before constructing
                // output or changing the persisted consumption bit.
                let output=admission.retainObservation(encodedCeiling,nodeCeiling,{=>
                    let values=ArrayList<AgentValue>()
                    for(state in hubMessages where !state.consumed && state.snapshot.to==caller.id &&
                        state.rootSessionId.value==caller.rootSessionId.value){
                        let m=state.snapshot
                        values.add(objectValue([ValueField("id",textValue(m.id)),ValueField("sender",textValue(m.from)),
                            ValueField("recipient",textValue(m.to)),ValueField("body",textValue(m.message)),
                            ValueField("reply_to",textValue(m.replyTo)),ValueField("created_at",integerValue(m.createdAt))]))
                    }
                    objectValue([ValueField("schema",textValue("axyndra.peer-messages/v1")),ValueField("messages",listValue(values.toArray()))])
                })
                if(!peek && !output.field("messages").getOrThrow().items.isEmpty()){
                    let consumed=ArrayList<ProductHubMessageState>()
                    for(state in hubMessages where !state.consumed && state.snapshot.to==caller.id &&
                        state.rootSessionId.value==caller.rootSessionId.value){state.consumed=true;consumed.add(state)}
                    match(persistRootLocked(caller.rootSessionId)){
                        case Result.Ok(_)=>()
                        case Result.Err(error)=>
                            for(state in consumed){state.consumed=false}
                            rememberTaskPersistenceFailureLocked(caller.rootSessionId,error)
                            return Result.Err(error)
                    }
                }
                Result.Ok(ToolResult(admission.callId,output))
            } finally {lock.unlock()}
        } finally {lease.close()}
    }

    // Current same-root metadata only. Native owns the decision whether this
    // state needs an additional canonical read; no task or budget is changed.
    private func pluginPeerMemberSnapshotLocked111(context:ToolInvocationContext,id:String,
        retain:(Int64,Int64,()->AgentValue)->AgentValue):Result<AgentValue> {
        if(closing){return taskError("peer.owner_closed","member owner is closing")}
        let caller=hubIdentityLocked(context)
        let state=match(findSubagentLocked(id)){case Some(value)=>value
            case None=>return taskError("peer.member_missing","member is not present in the actual root")}
        if(state.parentSessionId.value!=caller.rootSessionId.value || state.id==caller.id) {
            return taskError("peer.member_scope_invalid","member is foreign or the actual caller") }
        var bytes:Int64=8192
        for(text in [caller.id,caller.sessionId.value,caller.rootSessionId.value,state.id,state.sessionId.value,
            state.runId.value,state.status,state.agentSource]) {
            if(text.size>Int64.Max/12 || bytes>Int64.Max-text.size*6) {
                return taskError("peer.observation_size_invalid","member metadata invoice overflow") }
            bytes+=text.size*6
        }
        let revision=match(stateRevisions.get(caller.rootSessionId.value)){case Some(value)=>value;case None=>0}
        Result<AgentValue>.Ok(retain(bytes,256,{=>objectValue([
            ValueField("schema",textValue("axyndra.peer-member-snapshot/v1")),ValueField("sender",textValue(caller.id)),
            ValueField("sender_session",textValue(caller.sessionId.value)),ValueField("root_thread",textValue(caller.rootSessionId.value)),
            ValueField("root_revision",integerValue(revision)),ValueField("id",textValue(state.id)),
            ValueField("thread_id",textValue(state.sessionId.value)),ValueField("run_id",textValue(state.runId.value)),
            ValueField("status",textValue(state.status)),ValueField("source_identity",textValue(state.agentSource)),
            ValueField("updated_at",integerValue(state.lastUpdate)),ValueField("execution_in_progress",boolValue(state.executionInProgress)),
            ValueField("launch_in_progress",boolValue(state.launchInProgress)),ValueField("finishing",boolValue(state.finishing)),
            ValueField("budget_held",boolValue(childBudgetLeases.get(id).isSome())),
            ValueField("completion_done",boolValue(state.pluginCompletionDone111))])}))
    }
    func observePluginPeerPreparation111(context:ToolInvocationContext,id:String,
        scope:HostPluginPeerPreparationSnapshot111):Result<AgentValue> {
        match(scope.check(context,id)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let result:Result<AgentValue>
        lock.lock()
        try {result=pluginPeerMemberSnapshotLocked111(context,id,{bytes,nodes,build=>scope.retainObservation(bytes,nodes,build)})}
        finally{lock.unlock()}
        match(scope.check(context,id)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        result
    }

    func readPluginPeerMember111(context:ToolInvocationContext,request:AgentValue,
        read:HostPluginPeerReadCustody111):Result<AgentValue> {
        match(read.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let runtime=match(attachedProduct()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let id=httpIntentText(request,"recipient")
        let priorRun:RunId
        lock.lock()
        try {
            let observed=match(pluginPeerMemberSnapshotLocked111(context,id,{bytes,nodes,build=>read.retainObservation(bytes,nodes,build)})) {
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            if(canonicalAgentValue(observed)!=canonicalAgentValue(request.field("member_snapshot").getOrThrow())) {
                return taskError("peer.member_changed","member changed after the original preparation observation") }
            if(closing){return taskError("peer.owner_closed","peer owner is closing")}
            let caller=hubIdentityLocked(context)
            let state=match(findSubagentLocked(id)){case Some(value)=>value
                case None=>return taskError("peer.member_missing","member is not present in the actual root")}
            if(state.parentSessionId.value!=caller.rootSessionId.value || id==caller.id) {
                return taskError("peer.member_scope_invalid","member is foreign or the actual caller") }
            if(!["completed","failed","cancelled"].contains(state.status) || state.executionInProgress ||
                state.launchInProgress || state.finishing || childBudgetLeases.get(id).isSome() ||
                !state.pluginCompletionDone111 || state.pluginAdmission111.isNone() || !pluginWorkersReturnedLocked111(state)) {
                return taskError("peer.member_unsettled","member has no completed physical and budget custody") }
            // This snapshot copies no history or request graph. All metadata
            // containers are prepaid before producing even the read frame.
            let _=read.retainObservation(4096,64,{=>nullValue()})
            priorRun=state.runId
        } finally {lock.unlock()}
        let actual=match(runtime.client.find(priorRun)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        if(!isTerminalRunState(actual.status) || actual.status==RunState.RecoveryRequired) {
            return taskError("peer.member_run_unsettled","actual child Run has not reached a settled terminal state") }
        match(read.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        try {
            let observed=match(pluginPeerMemberSnapshotLocked111(context,id,{bytes,nodes,build=>read.retainObservation(bytes,nodes,build)})) {
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            if(canonicalAgentValue(observed)!=canonicalAgentValue(request.field("member_snapshot").getOrThrow())) {
                return taskError("peer.member_changed","member changed while checking its actual terminal Run") }
            let caller=hubIdentityLocked(context)
            let state=match(findSubagentLocked(id)){case Some(value)=>value
                case None=>return taskError("peer.member_missing","member disappeared before its observation")}
            if(closing || state.parentSessionId.value!=caller.rootSessionId.value || id==caller.id ||
                state.runId.value!=priorRun.value || state.sessionId.value!=actual.sessionId.value ||
                !["completed","failed","cancelled"].contains(state.status) || state.executionInProgress ||
                state.launchInProgress || state.finishing || childBudgetLeases.get(id).isSome() ||
                !state.pluginCompletionDone111 || state.pluginAdmission111.isNone() || !state.capabilityCeilingKnown ||
                !pluginWorkersReturnedLocked111(state)) {
                return taskError("peer.member_changed","member changed while its actual terminal Run was checked") }
            if(messageCounter==Int64.Max){return taskError("peer.counter_exhausted","message counter cannot advance")}
            // The prior owner is consulted for descriptive frozen data only.
            // It is never used as the authority for the next Run. A persisted
            // historical-definition reader will be a separate verified path;
            // absent live data currently refuses this incomplete WIP route.
            let definition=state.pluginAdmission111.getOrThrow().frozenDefinition111()
            var bytes=logicalJsonWriteReservationBytes(definition,8388608)+16384
            var nodes=logicalJsonValueNodeCount(definition)+256
            for(text in [caller.id,caller.sessionId.value,caller.rootSessionId.value,state.id,state.sessionId.value,
                state.runId.value,state.status,state.agentSource,httpIntentText(request.field("input_payload").getOrThrow(),"sha256")]) {
                if(text.size>Int64.Max/12 || bytes>Int64.Max-text.size*6) {
                    return taskError("peer.observation_size_invalid","member observation invoice overflow") }
                bytes+=text.size*6
            }
            for(capability in state.capabilities.values) {
                if(capability.resource.size>Int64.Max/12 || bytes>Int64.Max-(capability.resource.size*6+512) || nodes>Int64.Max-8) {
                    return taskError("peer.observation_size_invalid","member ceiling invoice overflow") }
                bytes+=capability.resource.size*6+512;nodes+=8
            }
            let stamp=nowMillis()
            let output=read.retainObservation(bytes,nodes,{=>
                let target=objectValue([ValueField("id",textValue(state.id)),ValueField("thread_id",textValue(state.sessionId.value)),
                    ValueField("run_id",textValue(state.runId.value)),ValueField("status",textValue(state.status)),
                    ValueField("source_identity",textValue(state.agentSource)),
                    ValueField("capability_ceiling",taskPersistCapabilitiesValue(state.capabilities)),ValueField("definition",definition)])
                let message=objectValue([ValueField("id",textValue("message-"+stamp.toString()+"-"+(messageCounter+1).toString())),
                    ValueField("input_payload",request.field("input_payload").getOrThrow()),
                    ValueField("created_at",integerValue(stamp))])
                objectValue([ValueField("schema",textValue(PLUGIN_PEER_READ_RESULT111)),ValueField("binding",request.field("binding").getOrThrow()),
                    ValueField("projection_digest",request.field("projection_digest").getOrThrow()),
                    ValueField("request_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
                    ValueField("observation",objectValue([ValueField("sender",textValue(caller.id)),
                        ValueField("sender_session",textValue(caller.sessionId.value)),ValueField("root_thread",textValue(caller.rootSessionId.value)),
                        ValueField("counter",integerValue(messageCounter)),ValueField("message",message),ValueField("target",target)]))])
            })
            Result.Ok(output)
        } finally {lock.unlock()}
    }

    func pluginParentResultPersisted111(context:ToolInvocationContext,result:ToolResult):Result<Unit> {
        // The observer chooses an already-live actual child owner. The caller
        // cannot select a parent using a serialized receipt or matching name.
        let parent:?OperationId
        let persistence:?ProductTaskPersistence
        lock.lock()
        try {
            var found:?OperationId=Option<OperationId>.None
            for(state in records where state.pluginOriginalAdmission111.isSome()) {
                let matched=state.pluginOriginalAdmission111.getOrThrow().persistedParent(context,result)
                if(matched.isSome()){found=matched;break}
            }
            parent=found;persistence=taskPersistence
        }finally{lock.unlock()}
        if(parent.isNone()){return Result<Unit>.Ok(())}
        if(persistence.isNone()){return taskError("peer.persistence_missing","retained parent delivery has no actual durable store")}
        match(persistence.getOrThrow().verifyCompletedPeerParent111(parent.getOrThrow(),context.runId,context.sessionId,
            context.epoch,result.receiptId)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()
        }
        deliverHubMessagesAfterParentResult(context.sessionId,result.callId)
    }

    // Neutral membership and transport facts. This function runs under the
    // existing Task lock; the installed package owns prompt/output grammar.
    private func snapshotPluginPeerDeliveryLocked111(context: ToolInvocationContext, request: AgentValue,
        stamp: Int64, admission: HostPluginChildAdmission111): Result<AgentValue> {
        if(closing){return taskError("peer.owner_closed","peer owner is closing")}
        let _=admission.retainObservation(4096,64,{=>nullValue()})
        let caller=hubIdentityLocked(context)
        var pendingParentCall=caller.parentToolCallId
        if(caller.sessionId.value!=caller.rootSessionId.value && taskPersistence.isSome()) {
            let state=findSubagentLocked(caller.id).getOrThrow()
            if(state.pluginAdmission111.isSome()) {
                let original=match(state.pluginOriginalAdmission111) {
                    case Some(value)=>value
                    case None=>return taskError("peer.parent_identity_missing","actual child lost its original parent ACK relationship") }
                if(original.originalParentOperation111.isNone()) {
                    return taskError("peer.parent_identity_missing","actual child lost its original parent identity") }
                let parent=original.originalParentOperation111.getOrThrow()
                match(taskPersistence.getOrThrow().completedPeerParent111(parent,state.parentRunId,state.parentSessionId,
                    original.originalParentEpoch111,"receipt-"+parent.value)) {
                    case Result.Err(error)=>return Result.Err(error)
                    case Result.Ok(true)=>pendingParentCall=""
                    case Result.Ok(false)=>()
                }
            }
        }
        let waitForParent=pendingParentCall
        let selector=request.field("recipient").getOrThrow()
        let kind=httpIntentText(selector,"kind");let member=httpIntentText(selector,"id")
        if(request.field("member_snapshot").isSome()) {
            let snapshot=match(pluginPeerMemberSnapshotLocked111(context,member,
                {bytes,nodes,build=>admission.retainObservation(bytes,nodes,build)})) {
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            if(kind!="member" || canonicalAgentValue(snapshot)!=canonicalAgentValue(request.field("member_snapshot").getOrThrow())) {
                return taskError("peer.member_changed","frozen member changed before actual publication") }
        }
        let body=httpIntentText(request,"body");let reply=httpIntentText(request,"reply_to")
        let bytes=AtomicInt64(4096);let nodes=AtomicInt64(64);let count=AtomicInt64(0)
        let visit={ emit:(String,SessionId,String,String,String)->Unit =>
            if((kind=="root" || kind=="others") && caller.sessionId.value!=caller.rootSessionId.value) {
                emit("Main",caller.rootSessionId,"","root",waitForParent) }
            for(record in records where record.parentSessionId.value==caller.rootSessionId.value &&
                ((kind=="member" && record.id==member) ||
                 (kind=="others" && record.id!=caller.id && (record.status=="running" || record.status=="blocked")))) {
                emit(record.id,record.sessionId,record.runId.value,record.status,"") }
        }
        let problem=AtomicInt64(0)
        visit({ id,session,run,status,waitCall =>
            if(id==caller.id){problem.store(1)}
            else if(status!="root" && status!="running" && status!="blocked") {
                // A fresh frozen resume primitive is required. Do not enqueue
                // a message and report delivery without actually admitting it.
                problem.store(2)
            }
            var part:Int64=1024
            for(text in [id,session.value,run,status,waitCall,body,reply,caller.id]) {
                if(text.size>Int64.Max/12 || part>Int64.Max-text.size*6){problem.store(3)}
                else{part+=text.size*6}
            }
            if(bytes.load()>Int64.Max-part || nodes.load()>Int64.Max-32 || count.load()==Int64.Max){problem.store(3)}
            else{let _=bytes.fetchAdd(part);let _=nodes.fetchAdd(32);let _=count.fetchAdd(1)}
        })
        if(problem.load()!=0){return taskError(if(problem.load()==1){"peer.self_send"}else if(problem.load()==2){"peer.resume_required"}
            else{"peer.observation_size_invalid"},"actual recipient cannot accept this frozen delivery")}
        if(count.load()==0){return taskError("peer.member_missing","no eligible actual member is selected")}
        if(messageCounter>Int64.Max-count.load()){return taskError("peer.counter_exhausted","message counter cannot advance")}
        let snapshot=admission.retainObservation(bytes.load(),nodes.load(),{=>
            let values=ArrayList<AgentValue>();let ordinal=AtomicInt64(messageCounter)
            visit({id,session,run,status,waitCall=>
                let next=ordinal.fetchAdd(1)+1
                values.add(objectValue([ValueField("id",textValue("message-"+stamp.toString()+"-"+next.toString())),
                    ValueField("recipient",textValue(id)),ValueField("recipient_session",textValue(session.value)),
                    ValueField("recipient_run",textValue(run)),ValueField("recipient_status",textValue(status)),
                    ValueField("body",textValue(body)),ValueField("reply_to",textValue(reply)),
                    ValueField("created_at",integerValue(stamp)),ValueField("wait_call_id",textValue(waitCall))]))
            })
            objectValue([ValueField("schema",textValue("axyndra.peer-delivery-observation/v1")),
                ValueField("sender",textValue(caller.id)),ValueField("sender_session",textValue(caller.sessionId.value)),
                ValueField("root_thread",textValue(caller.rootSessionId.value)),ValueField("counter",integerValue(messageCounter)),
                ValueField("messages",listValue(values.toArray()))])
        })
        Result.Ok(snapshot)
    }

    // One durable publication finishes its complete original frame before the
    // same admitted canonical child begins its original mailbox continuation.
    // A delivered request is not a reply, worker return, or consumption ACK.
    func sendPluginPeerReply178(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        let sent = match (sendPluginPeerMessage111(context, request, admission)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value }
        let meter = admission.createJobSnapshotMeter165()
        try { sendPluginPeerReplyFrame178(context, request, sent, admission, meter) }
        finally { meter.closeUnpublished151() }
    }
    private func sendPluginPeerReplyFrame178(context: ToolInvocationContext, request: AgentValue,
        sent: ToolResult, admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151): Result<ToolResult> {
        meter.fundAdditional151(8192, 16)
        let first = ProductPeerWaitSelection171()
        let waiting = request.field("await_reply").getOrThrow()
        let sender = waiting.field("sender").getOrThrow().text
        let timeout = Int64.parse(waiting.field("timeout_ms").getOrThrow().asNumberText())
        let identity = lockPeerReplyIdentity178(context, admission, meter)
        let caller = match (identity) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        // Original sendHubMessage starts this deadline AFTER real publication
        // and external-delivery frames have returned; zero remains unbounded.
        let started = nowMillis()
        while (true) {
            match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (admission.acquirePeerReplyObservation178()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let result = try {
                observePluginPeerWait171(context, sender, caller.id, caller.rootSessionId,
                    timeout > 0 && nowMillis() - started >= timeout, admission, meter, first)
            } finally { fence.close() }
            let observed = match (result) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            match (observed) {
                case Some(value) =>
                    match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    let sendShape = meter.measureBorrowedValue151(sent.output)
                    let replyShape = meter.measureBorrowedValue151(value.output)
                    if (sendShape.bytes > Int64.Max - replyShape.bytes - 8192 ||
                        sendShape.nodes > Int64.Max - replyShape.nodes - 16) {
                        return taskError("peer.observation_size_invalid", "reply result invoice overflow") }
                    let output = admission.retainObservation(sendShape.bytes + replyShape.bytes + 8192,
                        sendShape.nodes + replyShape.nodes + 16, { =>
                            objectValue([ValueField("schema", textValue("axyndra.peer-delivery-result/v1")),
                                ValueField("sender", sent.output.field("sender").getOrThrow()),
                                ValueField("deliveries", sent.output.field("deliveries").getOrThrow()),
                                ValueField("waited", value.output.field("waited").getOrThrow())]) })
                    return Result.Ok(ToolResult(admission.callId, output))
                case None => () }
            sleep(Duration.millisecond * 10)
        }
        taskError("peer.reply_unknown", "actual reply continuation did not return")
    }
    // Only scalar lengths of the original locked record are borrowed here.
    // Every field retained by ProductHubIdentity is prepaid in the same meter
    // before the original constructor can allocate or return its wrapper.
    private func fundPeerReplyIdentityLengths178(meter: HostPaidValueProjection151,
        idBytes: Int64, sessionBytes: Int64, rootBytes: Int64,
        parentCallBytes: Int64, statusBytes: Int64): Result<Unit> {
        let maximum = (Int64.Max - 4096) / 6
        var total: Int64 = 0
        for (bytes in [idBytes, sessionBytes, rootBytes, parentCallBytes, statusBytes]) {
            if (bytes < 0 || bytes > maximum - total) {
                return taskError("peer.observation_size_invalid", "reply identity invoice overflow") }
            total += bytes
        }
        meter.fundAdditional151(total * 6 + 4096, 8)
        Result<Unit>.Ok(())
    }
    private func lockPeerReplyIdentity178(context: ToolInvocationContext,
        admission: HostPluginChildAdmission111, meter: HostPaidValueProjection151): Result<ProductHubIdentity> {
        let fence = match (admission.acquirePeerReplyObservation178()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            lock.lock()
            try {
                if (closing) { return taskError("peer.owner_closed", "mailbox owner is closing") }
                for (record in records where record.runId.value == context.runId.value) {
                    match (fundPeerReplyIdentityLengths178(meter, record.id.size, record.sessionId.value.size,
                        record.parentSessionId.value.size, record.parentToolCallId.size, record.status.size)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    return Result.Ok(hubIdentityLocked(context))
                }
                // Main retains both complete SessionId values and the original
                // constructor defaults: parentToolCallId="", status="running".
                match (fundPeerReplyIdentityLengths178(meter, 4, context.sessionId.value.size,
                    context.sessionId.value.size, 0, 7)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                Result.Ok(hubIdentityLocked(context))
            } finally { lock.unlock() }
        } finally { fence.close() }
    }


    func sendPluginPeerMessage111(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        if(request.field("resume").isSome()){return resumePluginPeerMember111(context,request,admission)}
        match(admission.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let runtime=match(attachedProduct()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let stamp=nowMillis()
        let observed:AgentValue
        lock.lock()
        try {observed=match(snapshotPluginPeerDeliveryLocked111(context,request,stamp,admission)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}}
        finally{lock.unlock()}
        // Pure formatting holds neither Registry nor Task/SQLite locks. Full
        // Source/config/generation is checked around the actual pure callback.
        let formatted=match(admission.formatMessage(observed)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!httpIntentExactFields(formatted,["messages"]) || formatted.field("messages").getOrThrow().unifiedKind!=ValueKind.List ||
            formatted.field("messages").getOrThrow().items.size!=observed.field("messages").getOrThrow().items.size) {
            return taskError("peer.format_invalid","formatter changed the actual delivery set") }
        let messages=observed.field("messages").getOrThrow().items
        let texts=formatted.field("messages").getOrThrow().items
        var outputBytes:Int64=4096
        for(i in 0..messages.size) {
            if(!httpIntentExactFields(texts[i],["id","content"]) || httpIntentText(texts[i],"id")!=httpIntentText(messages[i],"id") ||
                texts[i].field("content").getOrThrow().unifiedKind!=ValueKind.Text) {
                return taskError("peer.format_invalid","formatter returned a different message identity") }
            for(text in [httpIntentText(texts[i],"content"),httpIntentText(messages[i],"body"),httpIntentText(messages[i],"reply_to"),
                httpIntentText(messages[i],"recipient_session"),httpIntentText(messages[i],"recipient"),httpIntentText(messages[i],"id"),
                httpIntentText(observed,"sender"),httpIntentText(observed,"root_thread")]) {
                if(text.size>Int64.Max/12 || outputBytes>Int64.Max-(text.size*6+512)) {
                    return taskError("peer.observation_size_invalid","delivery custody invoice overflow") }
                outputBytes+=text.size*6+512
            }
        }
        // Payment precedes all private message rows and immutable return data.
        // The mounted owner retains the aliases; callback return is not ACK.
        let deliveries=ArrayList<ProductHubMessageState>()
        let output=admission.retainObservation(outputBytes,64+messages.size*32,{=>
            let results=ArrayList<AgentValue>()
            for(i in 0..messages.size) {
                let message=messages[i]
                let snapshot=ProductHubMessageSnapshot(httpIntentText(message,"id"),httpIntentText(observed,"sender"),
                    httpIntentText(message,"recipient"),httpIntentText(message,"body"),httpIntentText(message,"reply_to"),stamp)
                deliveries.add(ProductHubMessageState(snapshot,SessionId(httpIntentText(message,"recipient_session")),
                    SessionId(httpIntentText(observed,"root_thread")),waitCallId:httpIntentText(message,"wait_call_id"),
                    deliveryText111:Some(httpIntentText(texts[i],"content"))))
                results.add(objectValue([ValueField("id",textValue(snapshot.id)),ValueField("recipient",textValue(snapshot.to)),
                    ValueField("delivered",boolValue(true))]))
            }
            objectValue([ValueField("schema",textValue("axyndra.peer-delivery-result/v1")),
                ValueField("sender",observed.field("sender").getOrThrow()),ValueField("deliveries",listValue(results.toArray()))])
        })
        let lease=match(admission.acquireSendLease()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try {
            lock.lock()
            try {
                let current=match(snapshotPluginPeerDeliveryLocked111(context,request,stamp,admission)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(canonicalAgentValue(current)!=canonicalAgentValue(observed)) {
                    return taskError("peer.membership_changed","actual recipients or message revision changed before publication") }
                match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let previous=hubMessages.toArray();let oldCounter=messageCounter
                for(delivery in deliveries){hubMessages.add(delivery);messageCounter+=1}
                pruneHubMessagesLocked()
                match(persistRootLocked(SessionId(httpIntentText(observed,"root_thread")))) {
                    case Result.Ok(_)=>()
                    case Result.Err(error)=>
                        hubMessages.clear();hubMessages.add(all:previous);messageCounter=oldCounter
                        rememberTaskPersistenceFailureLocked(SessionId(httpIntentText(observed,"root_thread")),error)
                        return Result.Err(error)
                }
            } finally {lock.unlock()}
            for(delivery in deliveries) {
                // The original parent-result hook drains this already durable
                // message only after its actual pending ToolResult is stored.
                if(delivery.waitCallId!=""){continue}
                match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(runtime.appendExternalMessageOnce(delivery.targetSessionId,"hub-delivery:"+delivery.snapshot.id,
                    ModelMessage(ModelRole.User,[ModelBlock(ModelBlockKind.Text,text:delivery.deliveryText111.getOrThrow())]),
                    source:"hub_delivery")) {
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()
                }
            }
            Result.Ok(ToolResult(admission.callId,output))
        } finally {lease.close()}
    }

    // A new incarnation is driven by this peer.send's live canonical child,
    // never by the historical child's terminal Source. The first parent and
    // Main ACK association remain the original immutable Task fields.
    private func resumePluginPeerMember111(context:ToolInvocationContext,input:AgentValue,
        admission:HostPluginChildAdmission111):Result<ToolResult> {
        match(admission.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let runtime=match(attachedProduct()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let resume=input.field("resume").getOrThrow();let proposal=resume.field("proposal").getOrThrow()
        let target=proposal.field("target").getOrThrow();let id=httpIntentText(target,"id")
        let snapshot=resume.field("read_request").getOrThrow().field("member_snapshot").getOrThrow()
        let old:ProductSubagentState
        lock.lock()
        try {
            let actual=match(pluginPeerMemberSnapshotLocked111(context,id,
                {bytes,nodes,build=>admission.retainObservation(bytes,nodes,build)})) {
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            if(canonicalAgentValue(actual)!=canonicalAgentValue(snapshot)) {
                return taskError("peer.member_changed","member changed before preparing its new incarnation") }
            old=findSubagentLocked(id).getOrThrow()
            if(!pluginWorkersReturnedLocked111(old) || old.pluginOriginalAdmission111.isNone() || !old.capabilityCeilingKnown ||
                canonicalAgentValue(taskPersistCapabilitiesValue(old.capabilities))!=canonicalAgentValue(target.field("capability_ceiling").getOrThrow())) {
                return taskError("peer.member_unsettled","old member has no exact settled physical owner and original ceiling") }
        }finally{lock.unlock()}
        let previous=match(runtime.client.find(old.runId)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        if(!isTerminalRunState(previous.status) || previous.status==RunState.RecoveryRequired ||
            previous.sessionId.value!=old.sessionId.value) {
            return taskError("peer.member_run_unsettled","previous actual child Run is not terminal") }
        let next=proposal.field("request").getOrThrow()
        // Original revival uses the current Root model and thinking defaults;
        // the Native recipe contributes only prompt/role ceiling/limits.
        let base=match(runtime.prepareRequest(httpIntentText(next,"prompt"),sessionId:Some(old.sessionId),modelOverride:runtime.model, inheritedModelSettings180: Some(context.modelSettingsDescriptor180()))) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        let data=try{ProductPluginChildRequest111(next,base.thinking)}catch(_:Exception) {
            return taskError("peer.resume_request_invalid","frozen resume data is invalid") }
        let capabilities=effectiveChildCapabilities(old.capabilities,data.ceiling,context.capabilities)
        let child=productPluginChildRequest111(base,data,capabilities,context.budget)
        if(old.depth>child.budget.maxDepth){return taskError("subagent.budget_exceeded","subagent resource budget exceeded")}
        match(admission.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let state=match(claimPluginPeerIncarnation111(context,input,old,child,admission)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        match(reserveChildBudget(context,id,executionBudgetFrom(child.budget))) {
            case Result.Err(error)=>
                let _=finishSubagent(id,"failed",error:error.message);releaseChildExecution(id);return Result.Err(error)
            case Result.Ok(_)=>() }
        match(startPluginWorker111<ToolResult>(state,{=>{=>runPluginChild111(runtime,id,child,admission)}})) {
            case Result.Err(error)=>
                let _=finishSubagent(id,"failed",error:error.message);releaseChildExecution(id);return Result.Err(error)
            case Result.Ok(_)=>() }
        while(true) {
            match(context.cancellation.check()) {
                case Result.Err(error)=>let _=cancelPluginChild111(runtime,id);return Result.Err(error)
                case Result.Ok(_)=>() }
            lock.lock()
            try {
                let actual=findSubagentLocked(id).getOrThrow()
                if(!refEq(actual,state) || actual.runId.value!=child.runId.value) {
                    return taskError("peer.member_changed","new incarnation lost its actual worker custody") }
                if(actual.pluginStartAdmitted111) {
                    let observed=resume.field("read_fact").getOrThrow().field("observation").getOrThrow()
                    let message=proposal.field("message").getOrThrow()
                    let output=admission.retainObservation(8192+id.size*6+httpIntentText(message,"id").size*6,128,{=>objectValue([
                        ValueField("schema",textValue("axyndra.peer-delivery-result/v1")),ValueField("sender",observed.field("sender").getOrThrow()),
                        ValueField("deliveries",listValue([objectValue([ValueField("id",message.field("id").getOrThrow()),
                            ValueField("recipient",textValue(id)),ValueField("delivered",boolValue(true))])]))])})
                    return Result.Ok(ToolResult(admission.callId,output)) }
                if(pluginWorkersReturnedLocked111(actual) || closing || actual.status=="cancelled") {
                    return taskError("peer.resume_not_admitted","new child returned or closed without actual Core admission") }
            }finally{lock.unlock()}
            sleep(Duration.millisecond*5)
        }
        taskError("peer.resume_not_admitted","new incarnation has no actual startup acknowledgement")
    }

    private func claimPluginPeerIncarnation111(context:ToolInvocationContext,input:AgentValue,old:ProductSubagentState,
        request:AgentRunRequest,admission:HostPluginChildAdmission111):Result<ProductSubagentState> {
        let resume=input.field("resume").getOrThrow();let proposal=resume.field("proposal").getOrThrow()
        let observed=resume.field("read_fact").getOrThrow().field("observation").getOrThrow()
        let identity=proposal.field("message").getOrThrow()
        var bytes:Int64=16384
        for(text in [old.id,old.agent,old.agentSource,old.description,old.task,old.assignment,old.sessionId.value,
            old.sessionRef,old.parentRunId.value,old.parentSessionId.value,old.parentToolCallId,
            httpIntentText(identity,"id"),httpIntentText(identity,"body"),httpIntentText(identity,"reply_to"),httpIntentText(observed,"sender")]) {
            if(text.size>Int64.Max/12 || bytes>Int64.Max-text.size*6) {
                return taskError("peer.resume_size_invalid","actual incarnation metadata invoice overflow") }
            bytes+=text.size*6
        }
        // Pay the overlapping old/new Task and mailbox fields before making
        // the new private state. Existing request custody is not refunded.
        let _=admission.retainObservation(bytes,512,{=>nullValue()})
        let state:ProductSubagentState
        let sinks: Array<ProductSubagentListener>
        old.settlementLock.lock()
        try {
            lock.lock()
            try {
                let current=match(pluginPeerMemberSnapshotLocked111(context,old.id,
                    {count,nodes,build=>admission.retainObservation(count,nodes,build)})) {
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
                if(closing || !refEq(findSubagentLocked(old.id).getOrThrow(),old) ||
                    canonicalAgentValue(current)!=canonicalAgentValue(resume.field("read_request").getOrThrow().field("member_snapshot").getOrThrow()) ||
                    old.executionInProgress || old.launchInProgress || old.finishing || childBudgetLeases.get(old.id).isSome() ||
                    !old.pluginCompletionDone111 || !pluginWorkersReturnedLocked111(old) || old.pluginOriginalAdmission111.isNone() ||
                    messageCounter!=taskPersistInteger(observed,"counter")) {
                    return taskError("peer.member_changed","same member, message counter or completed custody changed before claim") }
                match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                var index:Int64=0
                while(index<records.size && !refEq(records[index],old)){index+=1}
                if(index==records.size){return taskError("peer.member_changed","member disappeared before claim")}
                let previousYields=yields.toArray();let previousMessages=hubMessages.toArray();let previousCounter=messageCounter
                state=ProductSubagentState(old.id,old.index,old.agent,old.description,old.task,old.assignment,
                    old.sessionId,old.sessionRef,request.runId,old.parentRunId,old.parentSessionId,old.parentToolCallId,old.depth,
                    agentSource:admission.sourceIdentity,capabilities:request.capabilities,capabilityCeilingKnown:old.capabilityCeilingKnown,
                    budgetAuthority:old.budgetAuthority,startedAt:old.startedAt,status:"running",lastUpdate:nowMillis(),
                    settlementLock111:Some(old.settlementLock))
                state.budgetParentRunId=context.runId;state.pluginAdmission111=Some(admission)
                state.pluginOriginalAdmission111=old.pluginOriginalAdmission111;state.pluginCurrentBudgetAuthority111=Some(context)
                state.pendingRequest=Some(request);state.executionInProgress=true
                let message=ProductHubMessageSnapshot(httpIntentText(identity,"id"),httpIntentText(observed,"sender"),old.id,
                    httpIntentText(identity,"body"),httpIntentText(identity,"reply_to"),taskPersistInteger(identity,"created_at"))
                let delivery=ProductHubMessageState(message,old.sessionId,old.parentSessionId,
                    deliveryText111:Some(httpIntentText(proposal.field("request").getOrThrow(),"prompt")))
                records[index]=state;yields.add(ProductYieldState(request.runId));hubMessages.add(delivery);messageCounter+=1
                match(persistRootLocked(old.parentSessionId)) {
                    case Result.Err(error)=>
                        records[index]=old;yields.clear();yields.add(all:previousYields)
                        hubMessages.clear();hubMessages.add(all:previousMessages);messageCounter=previousCounter
                        rememberTaskPersistenceFailureLocked(old.parentSessionId,error);return Result.Err(error)
                    case Result.Ok(_)=>() }
                        let retained = match (admission.retainOriginalContextForChildWorker180(context)) {
                            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                        state.budgetAuthority = Some(retained); state.pluginCurrentBudgetAuthority111 = Some(retained)
                sinks=listenerSinksLocked()
            }finally{lock.unlock()}
        }finally{old.settlementLock.unlock()}
        emitToSinks(sinks,ProductSubagentEvent("lifecycle",state.snapshot()))
        Result.Ok(state)
    }

    func pluginBackgroundEnabled111(): Bool { asyncEnabled }

    func waitPluginChild111(context: ToolInvocationContext, receipt: VNextOperationReceipt,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        let id=httpIntentText(receipt.detail,"child_id")
        while (true) {
            // Recheck the actual waiting operation/source and selected package
            // on each wait interval. No Registry lock spans child execution.
            collectCompletedPluginChildContexts180()
            match(admission.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            lock.lock()
            try {
                let state=match(findSubagentLocked(id)){case Some(value)=>value;case None=>
                    return taskError("child.wait_owner_missing","historical child data cannot reconstruct its live owner")}
                if (closing || state.pluginAdmission111.isNone() || !state.pluginStartAdmitted111 ||
                    state.parentRunId.value!=context.runId.value || state.parentSessionId.value!=context.sessionId.value ||
                    state.parentToolCallId!=admission.parentCallId || state.runId.value!=httpIntentText(receipt.detail,"run_id") ||
                    state.sessionId.value!=httpIntentText(receipt.detail,"thread_id") ||
                    !admission.selectsStart(state.pluginAdmission111.getOrThrow(),receipt)) {
                    return taskError("child.wait_owner_changed","wait is not bound to this exact actual launch custody") }
                if (pluginWorkersReturnedLocked111(state) && !state.executionInProgress && !state.launchInProgress) {
                    return pluginLaunchResultLocked111(state,admission.callId) }
            } finally { lock.unlock() }
            sleep(Duration.millisecond*5)
        }
        taskError("child.wait_unavailable","child wait has no acknowledged result")
    }

    private func runPluginChild111(runtime: ProductRuntime, id: String, child: AgentRunRequest,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        try {
            let restriction = ProductPluginChildRestriction111(child, admission,
                { => retainedPluginChild111(id, child, admission) }, { => acknowledgePluginChild111(runtime, id, child, admission) })
            let started = childRunAction(id, { => runtime.client.startRestricted111(child, restriction,
                { event => recordChildEvent(id, event) }) })
            let initial = match (started) {
                case Result.Err(error) =>
                    let _ = finishSubagent(id, "failed", error: error.message)
                    return knownPluginChildTerminal111(id, admission.callId, error)
                case Result.Ok(item) => item }
            let outcome = match (reviewSubagentOutcome(runtime, id, child, initial)) {
                case Result.Err(error) =>
                    let _ = finishSubagent(id, "failed", error: error.message)
                    return knownPluginChildTerminal111(id, admission.callId, error)
                case Result.Ok(item) => item }
            match (outcome) {
                case AgentRunOutcome.AwaitingApproval(snapshot, approval) =>
                    applyRunSnapshot(id, snapshot)
                    let _ = tasks.transition(TaskId(id), TaskStatus.Blocked)
                    let _ = markSubagentAwaitingApproval(id, child, approval)
                case AgentRunOutcome.Completed(snapshot) =>
                    applyRunSnapshot(id, snapshot)
                    let ended = finishSubagent(id, runStateName(snapshot.status))
                    let _ = tasks.transition(TaskId(id), if (ended.status == "completed") { TaskStatus.Completed }
                        else if (ended.status == "cancelled") { TaskStatus.Cancelled }
                        else if (ended.status == "recovery_required") { TaskStatus.Blocked } else { TaskStatus.Failed })
            }
            lock.lock()
            try { pluginLaunchResultLocked111(findSubagentLocked(id).getOrThrow(), admission.callId) }
            finally { lock.unlock() }
        } catch (error: Exception) {
            let _ = finishSubagent(id, "failed", error: error.message)
            knownPluginChildTerminal111(id, admission.callId,
                AgentError(AgentErrorKind.InvalidInput, "child.worker_failed", "actual child worker did not complete"))
        } finally {
            releaseChildExecution(id)
        }
    }

    // A real Run failure is observed data, not an unknown launch. This route
    // is reachable only after finishSubagent has reloaded the actual terminal
    // Run, run and persisted the frozen finalizer, and settled the original
    // child budget. Unadmitted starts, cleanup debt and failed persistence keep
    // the original Err. No Rejected/Unknown Receipt is promoted here.
    private func knownPluginChildTerminal111(id: String, callId: String,
        original: AgentError): Result<ToolResult> {
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            if (!state.pluginStartAdmitted111 || state.launchInProgress ||
                !state.pluginCompletionDone111 || state.pluginCompletion111.isNone() ||
                state.pluginCompletionPending111.isNone() || state.pendingRequest.isSome() ||
                childBudgetLeases.get(id).isSome() ||
                (state.status != "failed" && state.status != "cancelled")) {
                return Result.Err(original)
            }
            pluginLaunchResultLocked111(state, callId)
        } finally { lock.unlock() }
    }

    private func pluginLaunchResultLocked111(state: ProductSubagentState, callId: String): Result<ToolResult> {
        if (!state.pluginStartAdmitted111) { return taskError("child.start_not_admitted", "no actual child Run was admitted") }
        if (state.status == "recovery_required") { return taskError("child.completion_recovery_required", state.error) }
        Result.Ok(ToolResult(callId, objectValue([
            ValueField("schema", textValue("axyndra.child-launch-result/v1")), ValueField("child_id", textValue(state.id)),
            ValueField("run_id", textValue(state.runId.value)), ValueField("thread_id", textValue(state.sessionId.value)),
            ValueField("status", textValue(state.status)), ValueField("background", boolValue(state.pluginJobKey111.isSome())),
            ValueField("completion", state.pluginCompletion111 ?? nullValue()),
            ValueField("state",objectValue([ValueField("id",textValue(state.id)),ValueField("index",integerValue(state.index)),
                ValueField("label",textValue(state.agent)),ValueField("source",textValue(state.agentSource)),
                ValueField("description",textValue(state.description)),ValueField("prompt",textValue(state.task)),
                ValueField("assignment",textValue(state.assignment)),ValueField("reference",textValue(state.sessionRef)),
                ValueField("tokens",integerValue(state.tokens)),ValueField("requests",integerValue(state.requests)),
                ValueField("duration_millis",integerValue(state.snapshot().durationMillis)),ValueField("error",textValue(state.error))]))])))
    }

    private func acknowledgePluginChild111(runtime: ProductRuntime, id: String, request: AgentRunRequest,
        admission: HostPluginChildAdmission111): Result<Unit> {
        match (retainedPluginChild111(id, request, admission)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let actual = match (runtime.client.find(request.runId)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (actual.runId.value != request.runId.value || actual.sessionId.value != request.sessionId.value || actual.status != RunState.Running) {
            return taskError("child.admission_snapshot_changed", "actual child snapshot does not match this start") }
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            if (closing || state.pluginCancellationRequested111 || state.pluginStartAdmitted111 || !state.launchInProgress || !state.executionInProgress ||
                !refEq(state.pendingRequest.getOrThrow(), request) || !refEq(state.pluginAdmission111.getOrThrow(), admission) ||
                childBudgetLeases.get(id).isNone()) {
                return taskError("child.admission_changed", "actual child custody changed before admission acknowledgement") }
            // Existing durable Task snapshot records the same child Run; no
            // separate launch/authority journal or claim is minted here.
            match (persistRootLocked(state.parentSessionId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            state.pluginStartAdmitted111 = true
            Result.Ok(())
        } finally { lock.unlock() }
    }

    private func createPluginChildJob111(context: ToolInvocationContext, state: ProductSubagentState): Result<Unit> {
        lock.lock()
        try {
            if (closing || !refEq(findSubagentLocked(state.id).getOrThrow(), state) || state.pluginJobKey111.isSome()) {
                return taskError("child.job_changed", "child custody cannot acquire another background worker") }
            let previousJobs = jobs.toArray(); let previousCounter = jobCounter
            jobCounter += 1
            let job = ProductAsyncJobState(state.id, state.id, "task", state.description,
                context.sessionId, state.parentSessionId, context.runId, jobCounter,
                parentToolCallId: state.parentToolCallId, executing: true)
            jobs.add(job); state.pluginJobKey111 = Some(job.key())
            match (persistRootLocked(state.parentSessionId)) {
                case Result.Err(error) =>
                    jobs.clear(); jobs.add(all: previousJobs); jobCounter = previousCounter; state.pluginJobKey111 = None
                    return Result.Err(error)
                case Result.Ok(_) => Result.Ok(()) }
        } finally { lock.unlock() }
    }

    private func isPluginChild111(id: String): Bool {
        lock.lock()
        try { match (findSubagentLocked(id)) { case Some(value) => value.pluginAdmission111.isSome(); case None => false } }
        finally { lock.unlock() }
    }

    private func cancelPluginChild111(runtime: ProductRuntime, id: String): Result<Unit> {
        let state = match (pluginChildState111(id)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let stage = match (startPluginWorker111<Unit>(state,
            { => { => cancelPluginChildAction111(runtime, id) } }, cleanup: true)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        stage.collect()
    }

    private func cancelPluginChildAction111(runtime: ProductRuntime, id: String): Result<Unit> {
        let runId: RunId
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            if (state.pluginAdmission111.isNone()) { return taskError("child.owner_missing", "plugin child owner is unavailable") }
            // A pending cancellation prevents the not-yet-admitted worker
            // from crossing Core's original startTurn even if no Run exists.
            state.pluginCancellationRequested111 = true; runId = state.runId
        } finally { lock.unlock() }
        let _ = runtime.cancelApprovalReview(runId)
        var acknowledged = false
        for (_ in 0..50) {
            match (runtime.client.cancel(runId)) {
                case Result.Ok(_) => acknowledged = true
                case Result.Err(error) =>
                    if (error.code != "persistence.not_found" && error.code != "run.sqlite_recovery_required") { return Result.Err(error) }
            }
            if (acknowledged) { break }
            let active = { => lock.lock(); try {
                let state = findSubagentLocked(id).getOrThrow()
                state.launchInProgress || (state.executionInProgress && !pluginWorkersReturnedLocked111(state))
            } finally { lock.unlock() } }()
            if (!active) { break }
            sleep(Duration.millisecond * 10)
        }
        let ended = finishSubagent(id, "cancelled")
        publishPluginChildJob111(id)
        if (ended.status == "recovery_required") { return taskError("child.cancellation_recovery_required", ended.error) }
        // A still-returning model worker owns its budget and finalizer. The
        // cancellation API acknowledges the request, not an invented result.
        Result.Ok(())
    }

    private func retryPluginChildCompletions111(): Unit {
        collectCompletedPluginChildContexts180()
        let pending = ArrayList<String>()
        lock.lock()
        try {
            for (state in records where state.pluginAdmission111.isSome() && state.status == "recovery_required" &&
                state.pluginStartAdmitted111 && pluginWorkersReturnedLocked111(state) && !state.launchInProgress && !state.executionInProgress) {
                pending.add(state.id)
            }
        } finally { lock.unlock() }
        for (id in pending) {
            // finishSubagent owns the existing exact-child settlement lock.
            // The finalizer itself rechecks actual terminal Run/artifact; this
            // path can neither restart a Run nor recreate an owner from disk.
            let state = match (pluginChildState111(id)) {
                case Result.Err(_) => continue; case Result.Ok(value) => value }
            match (startPluginWorker111<Unit>(state, { => { =>
                let _ = finishSubagent(id, "recovery_required")
                publishPluginChildJob111(id)
                Result<Unit>.Ok(())
            } }, idle: true, cleanup: true)) {
                case Result.Err(_) => ()
                case Result.Ok(stage) => let _ = stage.collect()
            }
        }
    }
    private func collectCompletedPluginChildContexts180(): Unit {
        while (true) {
            lock.lock()
            let selected = try {
                var found: ?ProductSubagentState = None<ProductSubagentState>
                for (state in records where state.pluginAdmission111.isSome() &&
                    state.pluginAdmission111.getOrThrow().hasRetainedOriginalContext180() && state.pluginCompletionDone111 &&
                    !state.launchInProgress && !state.executionInProgress && !state.finishing && childBudgetLeases.get(state.id).isNone() &&
                    pluginWorkersReturnedLocked111(state)) { state.finishing = true; found = Some(state); break }
                found
            } finally { lock.unlock() }
            if (selected.isNone()) { return }
            let state = selected.getOrThrow()
            try {
                // This is outside every worker action. Each original get helper
                // must return and detach its Future/callback before Context debt.
                for (worker in state.pluginWorkers111) { worker.collect() }
                var detached = true
                for (worker in state.pluginWorkers111) { if (!worker.originalFutureAliasesReturned180()) { detached = false } }
                if (!detached) { return }
                lock.lock()
                let actual = try {
                    if (findSubagentLocked(state.id).isNone() || !refEq(findSubagentLocked(state.id).getOrThrow(), state) ||
                        state.launchInProgress || state.executionInProgress || childBudgetLeases.get(state.id).isSome()) { return }
                    state.pluginCurrentBudgetAuthority111 = None<ToolInvocationContext>
                    state.budgetAuthority = None<ToolInvocationContext>
                    state.pluginAdmission111.getOrThrow()
                } finally { lock.unlock() }
                actual.returnContextAfterOriginalChildHelpers180()
            } finally { lock.lock(); try { state.finishing = false } finally { lock.unlock() } }
        }
    }


    private func publishPluginChildJob111(id: String): Unit {
        let key: ProductAsyncJobKey
        let snapshot: ProductAsyncJobSnapshot
        var terminal = false
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            key = match (state.pluginJobKey111) { case None => return; case Some(value) => value }
            let job = findJobLocked(key).getOrThrow()
            job.status = state.status; job.error = state.error
            job.executing = state.launchInProgress || state.executionInProgress
            job.updatedAt = nowMillis()
            // This is logical result publication inside the worker. The
            // physical Future must separately return before wait or restart.
            terminal = !job.executing && state.pluginCompletionDone111 && childBudgetLeases.get(id).isNone() &&
                (state.status == "completed" || state.status == "failed" || state.status == "cancelled")
            if (terminal) { job.result = state.pluginCompletion111; prepareJobSettlementLocked(job) }
            else if (job.status == "recovery_required") { prepareJobSettlementLocked(job) }
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Err(error) => markJobPersistenceRecoveryLocked(job, error); terminal = false
                case Result.Ok(_) => () }
            snapshot = job.snapshot()
        } finally { lock.unlock() }
        if (terminal) { emitJobEvent("settled", snapshot); injectJobSettlement(key, waitForParent: true) }
        else { emitJobEvent(if (snapshot.status == "recovery_required") { "recovery_required" } else { "updated" }, snapshot) }
    }

    private func createPluginChild111(runtime: ProductRuntime, context: ToolInvocationContext,
        data: ProductPluginChildRequest111, request: AgentRunRequest, depth: Int64,
        admission: HostPluginChildAdmission111): Result<ProductSubagentState> {
        lock.lock()
        let state: ProductSubagentState
        let sinks: Array<ProductSubagentListener>
        try {
            if (closing) { return taskError("task.runtime_closing", "child runtime is closing") }
            let previousRecords = records.toArray(); let previousYields = yields.toArray()
            let previousCounter = subagentCounter
            let allocated = reserveSubagentLocked(data.label)
            state = ProductSubagentState(allocated.id, allocated.index, data.label, data.description,
                data.prompt, data.prompt, request.sessionId, runtime.sessionReference(request.sessionId), request.runId,
                context.runId, context.sessionId, admission.parentCallId, depth,
                agentSource: admission.sourceIdentity, capabilities: request.capabilities, budgetAuthority: Some(context))
            state.pluginAdmission111 = Some(admission)
            state.pluginOriginalAdmission111 = Some(admission)
            state.pluginCurrentBudgetAuthority111 = Some(context)
            state.executionInProgress = true; state.pendingRequest = Some(request)
            records.add(state); yields.add(ProductYieldState(request.runId)); pruneSubagentsLocked()
            match (persistRootLocked(context.sessionId)) {
                case Result.Ok(_) => ()
                    let retained = match (admission.retainOriginalContextForChildWorker180(context)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    state.budgetAuthority = Some(retained); state.pluginCurrentBudgetAuthority111 = Some(retained)
                case Result.Err(error) =>
                    records.clear(); records.add(all: previousRecords)
                    yields.clear(); yields.add(all: previousYields); subagentCounter = previousCounter
                    rememberTaskPersistenceFailureLocked(context.sessionId, error)
                    return Result.Err(error) }
            sinks = listenerSinksLocked()
        } finally { lock.unlock() }
        emitToSinks(sinks, ProductSubagentEvent("lifecycle", state.snapshot()))
        Result.Ok(state)
    }

    // Called within the short Core admission window. The actual reservation,
    // request and one live primitive owner must still be the same objects.
    private func retainedPluginChild111(id: String, request: AgentRunRequest,
        admission: HostPluginChildAdmission111): Result<Unit> {
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            if (closing || state.pluginCancellationRequested111 || state.status != "running" || !state.launchInProgress || !state.executionInProgress ||
                state.finishing || state.pluginAdmission111.isNone() || !refEq(state.pluginAdmission111.getOrThrow(), admission) ||
                state.pendingRequest.isNone() || !refEq(state.pendingRequest.getOrThrow(), request) ||
                state.runId.value != request.runId.value || state.sessionId.value != request.sessionId.value ||
                childBudgetLeases.get(id).isNone()) {
                return taskError("child.admission_changed", "actual child custody or budget reservation changed") }
            match (state.pluginCurrentBudgetAuthority111) {
                case None => return taskError("child.authority_missing", "child lost its actual parent budget authority")
                case Some(parent) =>
                    if (parent.currentBudgetMode() == BudgetMode.Draining || parent.currentBudgetMode() == BudgetMode.Exhausted) {
                        return taskError("child.spawn_denied_budget_draining", "parent stopped child admission") }
                    parent.cancellation.check() }
        } finally { lock.unlock() }
    }

    private func validatePluginChildContinuation111(id: String): Result<Unit> {
        let admission: ?HostPluginChildAdmission111
        lock.lock()
        try { admission = findSubagentLocked(id).getOrThrow().pluginAdmission111 }
        finally { lock.unlock() }
        match (admission) {
            case None => Result.Ok(())
            case Some(value) => value.validateContinuation() }
    }

    // Caller owns the existing per-child settlementLock. No other finalizer
    // can run or settle this budget while the exact Native recipe is consumed.
    private func finalizePluginChild111(id: String, requestedStatus: String,
        requestedError: String): Result<(String, String)> {
        let state: ProductSubagentState
        let admission: HostPluginChildAdmission111
        lock.lock()
        try {
            state = findSubagentLocked(id).getOrThrow()
            admission = state.pluginAdmission111.getOrThrow()
            // Revalidate the actual terminal Run even when a prior finalizer
            // was persisted but its later Task publication failed.
            if (state.launchInProgress) { return taskError("child.execution_in_progress", "actual child execution has not returned") }
        } finally { lock.unlock() }
        let runtime = match (attachedProduct()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
        let snapshot: ?RunSnapshot = match (runtime.client.find(state.runId)) {
            case Result.Ok(item) => Some(item)
            case Result.Err(error) => if (error.code == "persistence.not_found") { None } else { return Result.Err(error) } }
        let observedRunId = state.runId.value
        let actualStatus = match (snapshot) {
            case Some(item) =>
                if (!isTerminalRunState(item.status) || item.status == RunState.RecoveryRequired) {
                    return taskError("child.execution_unsettled", "actual child Run still owns execution or recovery debt") }
                applyRunSnapshot(id, item)
                runStateName(item.status)
            case None => if (requestedStatus == "failed" || requestedStatus == "cancelled") { requestedStatus }
                else { return taskError("child.run_missing", "no actual child Run proves the requested terminal state") } }
        let yielded: ProductYieldState
        let yieldedRevision: Int64
        lock.lock()
        try { yielded = findYieldLocked(state.runId).getOrThrow(); yieldedRevision = yielded.revision150 }
        finally { lock.unlock() }
        // Cancellation of the original child must not prevent settling a
        // genuinely terminal result. This bounded pure query has no observer,
        // Source, new spawn authority or executable continuation.
        let retained = { => lock.lock(); try { state.pluginCompletionPending111 } finally { lock.unlock() } }()
        let value: AgentValue = match (retained) {
            case Some(item) =>
                match (admission.validateContinuation()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                item
            case None =>
                let owner = match (admission.deriveCompletionProjectionPayment151()) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let payment = try { HostPaidValueProjection151(owner) }
                    catch (error: Exception) { owner.close(); throw error }
                var transferred = false
                try {
                    let completionSource = CancellationSource(deadlineMillis: agentUtcMillis() + 5000)
                    let captured = ProductChildCompletionCapture151()
                    try {
                        if (snapshot.isSome()) {
                            let read = runtime.withTaskFinalText151(state.sessionId,
                                { invoice => payment.deriveDataPhase151(invoice) },
                                { => completionSource.token.check() }, { lastText =>
                                    captured.value = Some(productCompleteChildProjection151(admission, payment, state,
                                        yielded, actualStatus, requestedError, lastText, completionSource.token)) })
                            match (read) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                        } else {
                            captured.value = Some(productCompleteChildProjection151(admission, payment, state,
                                yielded, actualStatus, requestedError, "", completionSource.token)) }
                    } finally { completionSource.close() }
                    let projected = match (captured.take()) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    // The CAS helper holds no result alias after returning. A
                    // refused transfer clears the capture BEFORE the outer
                    // finally clears the private backing and closes its owner.
                    let committed = try { retainCompletedPluginProjection151(id, state, observedRunId,
                        yielded, yieldedRevision, projected) }
                        finally { projected.result = Option<AgentValue>.None }
                    match (committed) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    transferred = true
                    state.pluginCompletionPending111.getOrThrow()
                } finally { if (!transferred) { payment.closeUnpublished151() } }
        }
        let accepted = value.field("accepted").getOrThrow().asBool()
        let status = if (actualStatus == "completed" && !accepted) { "failed" } else { actualStatus }
        let diagnostic = if (!accepted) { value.field("diagnostic").getOrThrow().text } else { requestedError }
        lock.lock()
        try {
            if (!refEq(findSubagentLocked(id).getOrThrow(), state) || state.runId.value != observedRunId) {
                return taskError("child.completion_changed", "child changed during terminal interpretation") }
            if (state.pluginCompletionDone111) { return Result.Ok((status, diagnostic)) }
            state.pluginCompletion111 = Some(value.field("output").getOrThrow())
            state.pluginCompletionDone111 = true
            // Persist the complete observed result before settling its child
            // budget. A journal error retains the original owner/reservation.
            match (persistRootLocked(state.parentSessionId)) {
                case Result.Err(error) =>
                    state.pluginCompletion111 = None; state.pluginCompletionDone111 = false
                    return Result.Err(error)
                case Result.Ok(_) => () }
            // Keep the original paid full response for exact retry after a
            // later state-publication failure; no new query or refund.
            Result.Ok((status, diagnostic))
        } finally { lock.unlock() }
    }

    private func retainCompletedPluginProjection151(id: String, state: ProductSubagentState,
        observedRunId: String, yielded: ProductYieldState, yieldedRevision: Int64,
        projected: ProductChildProjection151): Result<Unit> {
        lock.lock()
        try {
            if (!refEq(findSubagentLocked(id).getOrThrow(), state) || state.runId.value != observedRunId ||
                !refEq(findYieldLocked(state.runId).getOrThrow(), yielded) || yielded.revision150 != yieldedRevision) {
                return taskError("child.completion_changed", "child or result slot changed during terminal projection") }
            projected.payment.fundAdditional151(4096, 4)
            projectionUnretired151.add(projected.payment)
            state.pluginProjectionPayment151 = Some(projected.payment)
            state.pluginCompletionPending111 = projected.result
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }







    private func reserveSubagentLocked(requested: String): ProductSubagentReservation {
        subagentCounter += 1
        let baseId = if (requested == "") {
            "subagent-" + subagentCounter.toString()
        } else {
            requested
        }
        var id = baseId
        var suffix: Int64 = 2
        while (findSubagentLocked(id).isSome() || hasJobIdLocked(id)) {
            id = baseId + "-" + suffix.toString()
            suffix += 1
        }
        ProductSubagentReservation(id, subagentCounter - 1)
    }

    private func recordChildEvent(id: String, event: AgentEvent): Unit {
        lock.lock()
        let snapshot: ?ProductSubagentSnapshot
        var progressChanged = false
        let sinks: Array<ProductSubagentListener>
        try {
            let state = findSubagentLocked(id)
            match (state) {
                case Some(value) =>
                    if (value.runId.value != event.runId.value) { return }
                    value.lastUpdate = nowMillis()
                    progressChanged = updateSubagentProgress(
                        value,
                        event
                    )
                    match (persistRootLocked(value.parentSessionId)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) =>
                            markSubagentPersistenceRecoveryLocked(value, error)
                            let _ = persistRootLocked(value.parentSessionId)
                    }
                    snapshot = Some(value.snapshot())
                    sinks = listenerSinksLocked()
                case None =>
                    snapshot = None
                    sinks = []
            }
        } finally {
            lock.unlock()
        }
        match (snapshot) {
            case Some(value) =>
                emitToSinks(
                    sinks,
                    ProductSubagentEvent(
                        "event",
                        value,
                        event: Some(event)
                    )
                )
                if (progressChanged) {
                    emitToSinks(
                        sinks,
                        ProductSubagentEvent("progress", value)
                    )
                }
            case None => ()
        }
    }

    private func markSubagentAwaitingApproval(
        id: String,
        request: AgentRunRequest,
        approval: ApprovalRequest
    ): ProductSubagentSnapshot {
        lock.lock()
        let snapshot: ProductSubagentSnapshot
        let sinks: Array<ProductSubagentListener>
        try {
            let state = findSubagentLocked(id).getOrThrow()
            state.status = "blocked"
            state.pendingRequest = Some(request)
            state.pendingApproval = Some(approval)
            state.currentTool = ""
            state.lastUpdate = nowMillis()
            match (persistRootLocked(state.parentSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    markSubagentPersistenceRecoveryLocked(state, error)
                    let _ = persistRootLocked(state.parentSessionId)
            }
            snapshot = state.snapshot()
            sinks = listenerSinksLocked()
        } finally {
            lock.unlock()
        }
        emitToSinks(
            sinks,
            ProductSubagentEvent("lifecycle", snapshot)
        )
        emitToSinks(
            sinks,
            ProductSubagentEvent(
                "approval",
                snapshot,
                approval: Some(approval)
            )
        )
        snapshot
    }

    private func reviveSubagent(
        id: String,
        message: ProductHubMessageSnapshot,
        authority: ToolInvocationContext
    ): Unit {
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(_) => return
        }
        let previous = lockAndFindAnySubagent(id, "")
        let state = match (previous) {
            case Some(value) => value
            case None => return
        }
        // Delivery to an already admitted child is generic coordination and
        // needs no fresh role query. Recheck under the same lock as revival.
        lock.lock()
        try {
            let current = findSubagentLocked(id).getOrThrow()
            if (current.status == "running" || current.status == "blocked") {
                let _ = runtime.appendExternalMessageOnce(current.sessionId, "hub-message-" + message.id,
                    hubMessageModelMessage(message), source: "hub")
                return
            }
            if (current.status == "recovery_required") { return }
        } finally { lock.unlock() }
        // Reviving a completed plugin child requires a new frozen canonical
        // primitive. The old generic mailbox cannot mint that live owner.
        if (state.agentSource.startsWith("plugin:")) { return }
        let role = match (queryProductWorkflowRole(runtime, state.agent, authority.sessionId,
            authority.cancellation, authority.runId.value + ":revive:" + id)) {
            // No new Run was claimed. Keep the durable message and original
            // child's historical outcome; a policy failure cannot rewrite it.
            case Result.Err(_) => return
            case Result.Ok(value) => value }
        let childCapabilities = effectiveChildCapabilities(
            capabilitiesForSubagent(id), role.ceiling, authority.capabilities
        )
        let base = match (runtime.prepareRequest(
            hubMessagePrompt(message),
            sessionId: Some(state.sessionId),
            modelOverride: runtime.model, inheritedModelSettings180: Some(authority.modelSettingsDescriptor180())
        )) { case Result.Err(error) =>
            let _ = finishSubagent(id, "failed", error: error.code + ": " + error.message)
            return
            case Result.Ok(value) => value }
        let request = productSubagentRequest(
            base,
            role,
            childCapabilities,
            authority.budget
        )
        while (true) {
            let claimed = claimRevivedChild(runtime, id, message, request, authority, role.pin)
            if (claimed < 0) { return }
            if (claimed > 0) { break }
            match (authority.cancellation.check()) {
                case Result.Err(_) => return
                case Result.Ok(_) => sleep(Duration.millisecond * 5)
            }
        }
        try {
            match (reserveChildBudget(authority, id, executionBudgetFrom(request.budget))) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    let _ = finishSubagent(id, "failed", error: error.code + ": " + error.message)
                    return
            }
            if (subagentStatus(id) == "cancelled") {
                let _ = finishSubagent(id, "cancelled")
                return
            }
            match (startChildRun(runtime, id, request)) {
                case Result.Ok(initial) => match (reviewSubagentOutcome(
                    runtime,
                    id,
                    request,
                    initial
                )) {
                    case Result.Ok(AgentRunOutcome.Completed(value)) =>
                        applyRunSnapshot(id, value)
                        let _ = finishSubagent(id, "completed")
                    case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, approval)) =>
                        applyRunSnapshot(id, snapshot)
                        let _ = markSubagentAwaitingApproval(id, request, approval)
                    case Result.Err(error) =>
                        let _ = finishSubagent(id, "failed", error: error.code + ": " + error.message)
                }
                case Result.Err(error) =>
                    let _ = finishSubagent(id, "failed", error: error.code + ": " + error.message)
            }
        } finally { releaseChildExecution(id) }
    }

    // 1 claims a fresh generation, 0 waits for a previous terminal worker,
    // -1 delivered to a live generation or left a recovery-required record.
    private func claimRevivedChild(
        runtime: ProductRuntime, id: String, message: ProductHubMessageSnapshot,
        request: AgentRunRequest, authority: ToolInvocationContext, workflowPin: ProductWorkflowPin
    ): Int64 {
        let sinks: Array<ProductSubagentListener>
        let snapshot: ProductSubagentSnapshot
        lock.lock()
        try {
            let current = findSubagentLocked(id).getOrThrow()
            if (current.status == "running" || current.status == "blocked") {
                let _ = runtime.appendExternalMessageOnce(
                    current.sessionId,
                    "hub-message-" + message.id,
                    hubMessageModelMessage(message),
                    source: "hub"
                )
                return -1
            }
            if (current.status == "recovery_required") { return -1 }
            if (current.executionInProgress || current.finishing || childBudgetLeases.get(id).isSome()) {
                return 0
            }
            current.executionInProgress = true
            current.runId = request.runId
            current.workflowPin = Some(workflowPin)
            current.agentSource = workflowPin.sourceIdentity()
            current.budgetParentRunId = authority.runId
            current.capabilities = request.capabilities
            current.status = "running"
            current.requests = 0
            current.tokens = 0
            current.toolCount = 0
            current.error = ""
            current.pendingRequest = Some(request)
            current.pendingApproval = None
            current.lastUpdate = nowMillis()
            current.currentTool = ""
            yields.add(ProductYieldState(request.runId))
            pruneSubagentsLocked()
            match (persistRootLocked(current.parentSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    markSubagentPersistenceRecoveryLocked(current, error)
                    current.executionInProgress = false
                    let _ = persistRootLocked(current.parentSessionId)
                    return -1
            }
            snapshot = current.snapshot()
            sinks = listenerSinksLocked()
        } finally {
            lock.unlock()
        }
        emitToSinks(
            sinks,
            ProductSubagentEvent("lifecycle", snapshot)
        )
        1
    }

    private func releaseChildExecution(id: String): Unit {
        lock.lock()
        try { findSubagentLocked(id).getOrThrow().executionInProgress = false }
        finally { lock.unlock() }
        publishPluginChildJob111(id)
    }

    private func startChildRun(
        runtime: ProductRuntime, id: String, request: AgentRunRequest
    ): Result<AgentRunOutcome> {
        childRunAction(id, { =>
            let pin: ProductWorkflowPin
            lock.lock()
            try {
                pin = match (findSubagentLocked(id).getOrThrow().workflowPin) {
                    case Some(value) => value
                    case None => return workflowConsumerError("workflow.live_policy_missing") }
            } finally { lock.unlock() }
            match (pin.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            runtime.client.start(request, { event => recordChildEvent(id, event) })
        })
    }

    private func childRunAction(
        id: String, action: () -> Result<AgentRunOutcome>
    ): Result<AgentRunOutcome> {
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            if (state.status == "cancelled" || closing) {
                return taskError<AgentRunOutcome>("child.cancelled_before_launch", "child launch was cancelled")
            }
            state.launchInProgress = true
        } finally { lock.unlock() }
        try { action() } catch (error: Exception) {
            taskError<AgentRunOutcome>("child.launch_exception", error.message)
        } finally {
            lock.lock()
            try { findSubagentLocked(id).getOrThrow().launchInProgress = false }
            finally { lock.unlock() }
        }
    }

    private func reviewSubagentOutcome(
        runtime: ProductRuntime,
        id: String,
        request: AgentRunRequest,
        initial: AgentRunOutcome
    ): Result<AgentRunOutcome> {
        childRunAction(id, { =>
            var outcome = initial
            while (true) {
                match (outcome) {
                    case AgentRunOutcome.Completed(_) => return Result.Ok(outcome)
                    case AgentRunOutcome.AwaitingApproval(snapshot, approval) =>
                        if (runtime.approvalSettings.mode == ApprovalRoutingMode.Manual) {
                            return Result.Ok(outcome)
                        }
                        match (validatePluginChildContinuation111(id)) {
                            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                        let review = runtime.reviewApproval(
                            request,
                            approval,
                            recentDenials: subagentApprovalDenials(id)
                        )
                        let reviewed = reviewedApprovalRequest(approval, review)
                        if (review.decision == ApprovalReviewDecision.AskUser) {
                            return Result.Ok(
                                AgentRunOutcome.AwaitingApproval(
                                    snapshot,
                                    reviewed
                                )
                            )
                        }
                        let decision = if (review.decision == ApprovalReviewDecision.Approve) {
                            ApprovalDecision.Approve
                        } else {
                            rememberSubagentApprovalDenial(
                                id,
                                reviewed.argumentHash + ": " + review.reason
                            )
                            ApprovalDecision.RejectWithReason(reviewerDenialMessage(review.reason))
                        }
                        outcome = match (runtime.client.decide(
                            request,
                            reviewed,
                            decision,
                            {event => recordChildEvent(id, event)}
                        )) {
                            case Result.Ok(value) => value
                            case Result.Err(error) => return Result.Err(error)
                        }
                }
            }
            Result.Ok(outcome)
        })
    }

    private func subagentApprovalDenials(id: String): Array<String> {
        lock.lock()
        try {
            match (findSubagentLocked(id)) {
                case Some(state) => state.recentApprovalDenials.toArray()
                case None => []
            }
        } finally {
            lock.unlock()
        }
    }

    private func rememberSubagentApprovalDenial(id: String, value: String): Unit {
        lock.lock()
        try {
            match (findSubagentLocked(id)) {
                case Some(state) =>
                    state.recentApprovalDenials.add(value)
                    while (state.recentApprovalDenials.size > 8) {
                        state.recentApprovalDenials.remove(at: 0)
                    }
                case None => ()
            }
        } finally {
            lock.unlock()
        }
    }

    private func applyRunSnapshot(
        id: String,
        snapshot: RunSnapshot
    ): Unit {
        lock.lock()
        try {
            match (findSubagentLocked(id)) {
                case Some(state) =>
                    if (state.runId.value != snapshot.runId.value) { return }
                    state.requests = snapshot.modelRequests
                    state.tokens = snapshot.inputTokens + snapshot.outputTokens
                    state.toolCount = snapshot.toolCalls
                    childUsage[id] = ExecutionUsage(
                        turns: snapshot.turns,
                        toolCalls: snapshot.toolCalls,
                        inputTokens: snapshot.inputTokens,
                        outputTokens: snapshot.outputTokens,
                        costMicros: match (snapshot.costMicros) {
                            case Some(value) => value
                            case None => 0
                        }
                    )
                    state.lastUpdate = nowMillis()
                    match (persistRootLocked(state.parentSessionId)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) =>
                            markSubagentPersistenceRecoveryLocked(state, error)
                            let _ = persistRootLocked(state.parentSessionId)
                    }
                case None => ()
            }
        } finally {
            lock.unlock()
        }
    }

    private func finishSubagent(
        id: String, status: String, error!: String = ""
    ): ProductSubagentSnapshot {
        let state: ProductSubagentState
        lock.lock()
        try { state = findSubagentLocked(id).getOrThrow() }
        finally { lock.unlock() }
        state.settlementLock.lock()
        let snapshot = try { settleAndFinishSubagent(id, status, error: error) }
            finally { state.settlementLock.unlock() }
        let sinks: Array<ProductSubagentListener>
        lock.lock()
        try { sinks = listenerSinksLocked() }
        finally { lock.unlock() }
        emitToSinks(sinks, ProductSubagentEvent("lifecycle", snapshot))
        snapshot
    }

    private func settleAndFinishSubagent(
        id: String,
        requestedStatus: String,
        error!: String = ""
    ): ProductSubagentSnapshot {
        var status = requestedStatus
        var finalError111 = error
        let pluginOwned: Bool
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            pluginOwned = state.pluginAdmission111.isSome()
            if (pluginOwned && state.launchInProgress) { return state.snapshot() }
        } finally { lock.unlock() }
        if (pluginOwned && status != "blocked") {
            match (finalizePluginChild111(id, status, finalError111)) {
                case Result.Ok((nextStatus, nextError)) => status = nextStatus; finalError111 = nextError
                case Result.Err(failure) =>
                    lock.lock()
                    try {
                        let state = findSubagentLocked(id).getOrThrow()
                        state.status = "recovery_required"
                        state.error = if (error == "") { "recovery_required: frozen child completion did not settle: " + failure.message }
                            else { error + "; recovery_required: frozen child completion did not settle: " + failure.message }
                        state.lastUpdate = nowMillis()
                        let _ = persistRootLocked(state.parentSessionId)
                        // No budget settlement, owner clear or fake completion.
                        return state.snapshot()
                    } finally { lock.unlock() }
            }
        }
        lock.lock()
        try {
            let state = findSubagentLocked(id).getOrThrow()
            state.finishing = true
        } finally { lock.unlock() }
        let budgetSettlementError: ?AgentError = if (status == "blocked") {
            None
        } else {
            match (settleChildBudget(id)) {
                case Result.Ok(_) => None
                case Result.Err(value) => Some(value)
            }
        }
        let effectiveStatus = if (budgetSettlementError.isSome()) {
            "recovery_required"
        } else if (subagentStatus(id) == "cancelled") { "cancelled" } else { status }
        let effectiveError = match (budgetSettlementError) {
            case Some(value) => "recovery_required: child budget settlement failed: " + value.message
            case None => finalError111
        }
        lock.lock()
        let snapshot: ProductSubagentSnapshot
        let sinks: Array<ProductSubagentListener>
        try {
            let state = findSubagentLocked(id).getOrThrow()
            state.status = effectiveStatus
            state.error = effectiveError
            state.pendingApproval = None
            if (effectiveStatus != "blocked") {
                state.pendingRequest = None
            }
            state.currentTool = ""
            state.lastUpdate = nowMillis()
            pruneSubagentsLocked()
            match (persistRootLocked(state.parentSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(persistError) =>
                    markSubagentPersistenceRecoveryLocked(state, persistError)
                    let _ = persistRootLocked(state.parentSessionId)
            }
            state.finishing = false
            snapshot = state.snapshot()
            sinks = listenerSinksLocked()
        } finally {
            lock.unlock()
        }
        let _ = sinks
        snapshot
    }

    // Authoritative child admission boundary. A parent in Draining or
    // Exhausted budget mode must not mint new child runs or leases even if a
    // tool somehow reaches this point; existing children keep their normal
    // cancel/settle/join lifecycle.
    private func reserveChildBudget(
        context: ToolInvocationContext,
        childId: String,
        child: ExecutionBudget
    ): Result<Unit> {
        let parentMode = context.currentBudgetMode()
        if (parentMode == BudgetMode.Draining || parentMode == BudgetMode.Exhausted) {
            return Result.Err(AgentError(
                AgentErrorKind.BudgetExceeded,
                "child.spawn_denied_budget_draining",
                "parent run is draining or exhausted; new child runs are not admitted",
                fields: [ErrorField("mode", budgetModeName(parentMode))]
            ))
        }
        let pool: ChildBudgetPool
        lock.lock()
        try {
            pool = match (childBudgetPools.get(context.runId.value)) {
                case Some(value) => value
                case None =>
                    pruneChildBudgetPoolsLocked()
                    let created = ChildBudgetPool(
                        context.budget,
                        context.budget.maxChildren,
                        maxConcurrentChildren: context.budget.maxConcurrentChildren
                    )
                    childBudgetPools[context.runId.value] = created
                    childBudgetOrder.add(context.runId.value)
                    created
            }
        } finally {
            lock.unlock()
        }
        var reservedLease: ?ChildBudgetLease = None
        while (true) {
            match (context.cancellation.check()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
            if (subagentStatus(childId) == "cancelled") {
                return taskError<Unit>("child.cancelled_before_admission", "child admission was cancelled")
            }
            if (context.currentBudgetMode() == BudgetMode.Draining ||
                context.currentBudgetMode() == BudgetMode.Exhausted) {
                return taskError<Unit>("child.spawn_denied_budget_draining", "parent stopped child admission")
            }
            match (pool.reserve(childId, child)) {
                case Result.Ok(value) =>
                    reservedLease = Some(value)
                    break
                case Result.Err(error) =>
                    if (error.code != "child.max_concurrent_children_exceeded") {
                        return Result.Err(error)
                    }
                    // Concurrency is a scheduling limit, not a reason to mark
                    // an accepted child job failed. Wait for an owned sibling
                    // lease to settle while still honoring parent cancellation
                    // and deadline propagation.
                    match (context.cancellation.check()) {
                        case Result.Ok(_) => sleep(Duration.millisecond * 5)
                        case Result.Err(cancelled) => return Result.Err(cancelled)
                    }
            }
        }
        lock.lock()
        try {
            childBudgetLeases[childId] = reservedLease.getOrThrow()
            childUsage[childId] = ExecutionUsage()
        } finally {
            lock.unlock()
        }
        Result.Ok(())
    }

    private func pruneChildBudgetPoolsLocked(): Unit {
        while (childBudgetOrder.size >= 256) {
            var removed = false
            for (index in 0..childBudgetOrder.size) {
                let runId = childBudgetOrder[index]
                let pool = childBudgetPools.get(runId)
                var retained = false
                for (record in records) {
                    if (record.budgetParentRunId.value == runId) { retained = true }
                    match (record.budgetAuthority) {
                        case Some(authority) => if (authority.runId.value == runId) { retained = true }
                        case None => ()
                    }
                }
                // A still-running canonical parent may delegate again even
                // after its old terminal child records were pruned.
                match (product) {
                    case Some(runtime) => match (runtime.client.find(RunId(runId))) {
                        case Result.Ok(snapshot) =>
                            if (!isTerminalRunState(snapshot.status)) { retained = true }
                        case Result.Err(error) => if (error.code != "persistence.not_found") { retained = true }
                    }
                    case None => ()
                }
                if (!retained && (pool.isNone() || pool.getOrThrow().snapshot().activeReservations == 0)) {
                    childBudgetPools.remove(runId)
                    childBudgetOrder.remove(at: index)
                    removed = true
                    break
                }
            }
            // More than 256 concurrently active parents is a legitimate burst;
            // never evict a live budget authority merely to satisfy the cache bound.
            if (!removed) { return }
        }
    }

    private func settleChildBudget(childId: String): Result<Unit> {
        let runId: RunId
        lock.lock()
        try {
            let state = findSubagentLocked(childId).getOrThrow()
            // Cancellation can be reported before the model worker returns.
            // Keep the reservation until that worker's final usage is visible.
            if (state.launchInProgress) { return Result.Ok(()) }
            if (childBudgetLeases.get(childId).isNone()) { return Result.Ok(()) }
            runId = state.runId
        } finally { lock.unlock() }
        match (attachedProduct()) {
            case Result.Ok(runtime) => match (runtime.client.find(runId)) {
                case Result.Ok(snapshot) =>
                    applyRunSnapshot(childId, snapshot)
                    if (snapshot.status == RunState.RecoveryRequired) {
                        return taskError<Unit>("child.budget_recovery_required",
                            "child Run has unfinished recovery work; budget reservation is retained")
                    }
                case Result.Err(error) =>
                    if (error.code != "persistence.not_found") { return Result.Err(error) }
            }
            case Result.Err(error) => return Result.Err(error)
        }
        lock.lock()
        try {
            let lease = match (childBudgetLeases.get(childId)) {
                case Some(value) => value
                // Concurrent cancellation/completion has already settled it.
                case None => return Result.Ok(())
            }
            let usage = match (childUsage.get(childId)) {
                case Some(value) => value
                case None => ExecutionUsage()
            }
            match (lease.settle(usage)) {
                case Result.Err(error) =>
                    if (error.code == "child.actual_usage_exceeds_reservation" ||
                        error.code == "child.parent_actual_usage_exceeded") {
                        childBudgetLeases.remove(childId)
                        childUsage.remove(childId)
                    }
                    Result.Err(error)
                case Result.Ok(_) =>
                    childBudgetLeases.remove(childId)
                    childUsage.remove(childId)
                    Result.Ok(())
            }
        } finally { lock.unlock() }
    }



    private func attachedProduct(): Result<ProductRuntime> {
        lock.lock()
        try {
            match (product) {
                case Some(value) => Result.Ok(value)
                case None => taskError<ProductRuntime>(
                    "task.runtime_unavailable",
                    "task runtime is not attached to the product"
                )
            }
        } finally {
            lock.unlock()
        }
    }

    private func depthForRun(runId: RunId): Int64 {
        lock.lock()
        try {
            for (record in records where record.runId.value == runId.value) {
                return record.depth
            }
            0
        } finally {
            lock.unlock()
        }
    }

    private func lockAndFindSubagent(
        rootSessionId: SessionId,
        id: String,
        sessionRef: String
    ): ?ProductSubagentSnapshot {
        lock.lock()
        try {
            for (record in records) {
                if (record.parentSessionId.value == rootSessionId.value && ((id != "" && record.id == id) || (sessionRef !=
                    "" && record.sessionRef == sessionRef))) {
                    return Some(record.snapshot())
                }
            }
            None
        } finally {
            lock.unlock()
        }
    }

    private func lockAndFindAnySubagent(
        id: String,
        sessionRef: String
    ): ?ProductSubagentSnapshot {
        lock.lock()
        try {
            for (record in records) {
                if ((id != "" && record.id == id) || (sessionRef != "" && record.sessionRef == sessionRef)) {
                    return Some(record.snapshot())
                }
            }
            None
        } finally {
            lock.unlock()
        }
    }

    private func findSubagentLocked(id: String): ?ProductSubagentState {
        for (record in records where record.id == id) {
            return Some(record)
        }
        None
    }
    private func capabilitiesForSubagent(id: String): CapabilitySet {
        lock.lock()
        try {
            match (findSubagentLocked(id)) {
                case Some(value) => value.capabilities
                case None => CapabilitySet()
            }
        } finally {
            lock.unlock()
        }
    }

    private func subagentStatus(id: String): String {
        lock.lock()
        try {
            match (findSubagentLocked(id)) {
                case Some(value) => value.status
                case None => ""
            }
        } finally {
            lock.unlock()
        }
    }

    private func subagentSnapshot(id: String): ProductSubagentSnapshot {
        lock.lock()
        try {
            findSubagentLocked(id).getOrThrow().snapshot()
        } finally {
            lock.unlock()
        }
    }

    private func findYieldLocked(runId: RunId): ?ProductYieldState {
        for (state in yields where state.runId.value == runId.value) {
            return Some(state)
        }
        None
    }

    private func listenerSinksLocked(): Array<ProductSubagentListener> { listeners.toArray() }

    private func pruneSubagentsLocked(): Unit {
        while (records.size > 256) {
            var removeIndex: Int64 = -1
            for (index in 0..records.size) {
                let status = records[index].status
                if (status != "running" && status != "blocked" && !records[index].executionInProgress && !records[index].launchInProgress && !records[index].finishing &&
                    childBudgetLeases.get(records[index].id).isNone()) {
                    removeIndex = index
                    break
                }
            }
            if (removeIndex < 0) { break }
            records.remove(at: removeIndex)
        }
        while (yields.size > 256) {
            var removeIndex: Int64 = -1
            for (index in 0..yields.size) {
                if (!yieldInUseLocked(yields[index].runId)) {
                    removeIndex = index
                    break
                }
            }
            if (removeIndex < 0) { break }
            yields.remove(at: removeIndex)
        }
    }

    private func yieldInUseLocked(runId: RunId): Bool {
        for (record in records where record.runId.value == runId.value &&
            (record.status == "running" || record.status == "blocked")) {
            return true
        }
        false
    }

    private func pruneJobsLocked(): Unit {
        while (jobs.size > 256) {
            var removed = false
            for (index in 0..jobs.size) {
                if (jobs[index].status != "running" && !jobs[index].executing && jobs[index].settlementInjected) {
                    jobs.remove(at: index)
                    removed = true
                    break
                }
            }
            if (!removed) {
                // Running work and receipts that have not reached the parent
                // transcript are never eviction candidates. The registry may
                // temporarily exceed its history target until one settles.
                break
            }
        }
    }

    private func hubIdentityLocked(context: ToolInvocationContext): ProductHubIdentity {
        for (record in records where record.runId.value == context.runId.value) {
            return ProductHubIdentity(
                record.id,
                record.sessionId,
                record.parentSessionId,
                parentToolCallId: record.parentToolCallId,
                status: record.status
            )
        }
        ProductHubIdentity(
            "Main",
            context.sessionId,
            context.sessionId
        )
    }

    private func hubTargetsLocked(
        sender: ProductHubIdentity,
        to: String
    ): Array<ProductHubIdentity> {
        let targets = ArrayList<ProductHubIdentity>()
        if (to == "all") {
            if (sender.id != "Main") {
                targets.add(
                    ProductHubIdentity(
                        "Main",
                        sender.rootSessionId,
                        sender.rootSessionId
                    )
                )
            }
            for (record in records where record.parentSessionId.value == sender.rootSessionId.value && record.id != sender
                .id && (record.status == "running" || record.status == "blocked")) {
                targets.add(
                    ProductHubIdentity(
                        record.id,
                        record.sessionId,
                        record.parentSessionId,
                        status: record.status
                    )
                )
            }
            return targets.toArray()
        }
        if (to == "Main") {
            if (sender.id != "Main") {
                targets.add(
                    ProductHubIdentity(
                        "Main",
                        sender.rootSessionId,
                        sender.rootSessionId
                    )
                )
            }
            return targets.toArray()
        }
        for (record in records where record.id == to && record.parentSessionId.value == sender.rootSessionId.value) {
            targets.add(
                ProductHubIdentity(
                    record.id,
                    record.sessionId,
                    record.parentSessionId,
                    status: record.status
                )
            )
            break
        }
        targets.toArray()
    }


    // Only actual resource facts are supplied here. Native owns all eight
    // grammars, defaults, readiness and output projections.
    func pluginProcessFacts180(context:ToolInvocationContext,meter:HostPaidValueProjection151):Result<AgentValue>{
        lock.lock()
        try{
            let actual=match(product){case Some(value)=>value;case None=>return taskError<AgentValue>(
                "hub.process_supervisor_unavailable","actual Product process owner is not attached")}
            meter.fundAdditional151(65536,16)
            // The frozen typed frontend represents an absent per-request
            // override as JSON null. Resolve it only for this preparation
            // fact; execution still consumes the resulting normalized plan.
            let mode = match (context.executionSettings180.field("shell_network_mode")) {
                case Some(value) => if (value.unifiedKind == ValueKind.Null) { actual.shellNetworkMode } else {
                    if (value.unifiedKind != ValueKind.Text) { return taskError<AgentValue>("config.invalid", "frozen shell network mode must be text") }
                    match (parseShellNetworkMode(value.text)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(selected) => selected } }
                case None => actual.shellNetworkMode }
            if (actual.shellNetworkMode == ShellNetworkMode.Proxy && mode != ShellNetworkMode.Proxy) {
                return taskError<AgentValue>("network.host_denied", "mediated Root networking cannot admit a HostNetwork policy")
            }
            Result.Ok(objectValue([ValueField("shell_mode",textValue(shellNetworkModeName(mode))),
                ValueField("broker_available",boolValue(processOwner180.isSome()))]))
        }finally{lock.unlock()}
    }
    func observePluginProcessPreparation180(context:ToolInvocationContext,request:AgentValue,
        meter:HostPaidValueProjection151):Result<AgentValue>{
        let supervisor=match(processSupervisorValue()){case Some(value)=>value;case None=>return taskError<AgentValue>(
            "hub.process_supervisor_unavailable","actual Product process owner is not attached")}
        Result.Ok(supervisor.captureNativeProcessTarget180(request,meter))
    }
    func executePluginProcess180(context:ToolInvocationContext,input:AgentValue,
        admission:HostPluginChildAdmission111):Result<ToolResult>{
        let lease=match(admission.acquireHubProcessService180()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let producer=lease.reserveControlBeforeClosure180()
        producer.fundProducerFrameBeforeEffect180(65536)
        let response=ProductActualProcessResponse180()
        producer.invokeSynchronousHelper180({=>
            match(executePluginProcessActualBody180(context,input,admission,lease)){
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(value)=>response.result=Some(value)}
        })
        // The entire original operation body/codec/SQL/socket frame returned
        // before classification/publication. Unknown launch/cleanup stays in
        // its original registered state and the paid producer.
        producer.noteSynchronousHelperReturned180()
        if(producer.hasOriginalFailure180()){
            return admission.publishActualProcessFailure180(context,producer)}
        let result=response.result.getOrThrow();response.result=None<ToolResult>
        if(!producer.retireObservedReturn()){
            throw HostHubProcessHeldProducerFailure180(producer)}
        // No source refund is inferred here. The exact Returning159 witness
        // only clears callback-to-Source aliases after their actual helpers
        // returned; output/error consumers and physical owners stay separate.
        let _=lease.collectNonPersistentRevocationReturn180()
        Result<ToolResult>.Ok(result)
    }

    func observePluginProcess197(context:ToolInvocationContext,input:AgentValue,
        admission:HostPluginChildAdmission111):Result<ToolResult>{
        if(!pluginHubProcessObservationInputValid197(input)){
            return taskError<ToolResult>("hub.process_observation_invalid","observation cannot request a process mutation")}
        let lease=match(admission.acquireHubProcessObservation197()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let producer=lease.reserveControlBeforeClosure180()
        producer.fundProducerFrameBeforeEffect180(65536)
        let response=ProductActualProcessResponse180()
        producer.invokeSynchronousHelper180({=>
            match(observePluginProcessActualBody197(context,input,admission,lease)){
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(value)=>response.result=Some(value)}
        })
        // The entire original operation body/codec/SQL/socket frame returned
        // before classification/publication. Unknown launch/cleanup stays in
        // its original registered state and the paid producer.
        producer.noteSynchronousHelperReturned180()
        if(producer.hasOriginalFailure180()){
            return admission.publishActualProcessFailure180(context,producer)}
        let result=response.result.getOrThrow();response.result=None<ToolResult>
        if(!producer.retireObservedReturn()){
            throw HostHubProcessHeldProducerFailure180(producer)}
        // No source refund is inferred here. The exact Returning159 witness
        // only clears callback-to-Source aliases after their actual helpers
        // returned; output/error consumers and physical owners stay separate.
        let _=lease.collectNonPersistentRevocationReturn180()
        Result<ToolResult>.Ok(result)
    }

    private func observePluginProcessActualBody197(context:ToolInvocationContext,input:AgentValue,
        admission:HostPluginChildAdmission111,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        if(!pluginHubProcessObservationInputValid197(input)){
            return taskError<ToolResult>("hub.process_observation_invalid","observation cannot request a process mutation")}
        let supervisor=match(processSupervisorValue()){case Some(value)=>value;case None=>return taskError<ToolResult>(
            "hub.process_supervisor_unavailable","actual Product process owner is not attached")}
        supervisor.observeNativeProcess180(input.field("request").getOrThrow(),context.sessionId.value,lease)
    }

    private func executePluginProcessActualBody180(context:ToolInvocationContext,input:AgentValue,
        admission:HostPluginChildAdmission111,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        let supervisor=match(processSupervisorValue()){case Some(value)=>value;case None=>return taskError<ToolResult>(
            "hub.process_supervisor_unavailable","actual Product process owner is not attached")}
        supervisor.observeNativeProcess180(input.field("request").getOrThrow(),context.sessionId.value,lease)

    }

    private func processSupervisorValue(): ?ProductProcessSupervisor {
        lock.lock()
        try {
            processSupervisor
        } finally {
            lock.unlock()
        }
    }





    private func pruneHubMessagesLocked(): Unit {
        while (true) {
            var overflowRoot = ""
            var overflowTarget = ""
            for (candidate in hubMessages) {
                var count: Int64 = 0
                for (state in hubMessages where state.rootSessionId.value == candidate.rootSessionId.value &&
                    state.snapshot.to == candidate.snapshot.to) {
                    count += 1
                }
                if (count > 100) {
                    overflowRoot = candidate.rootSessionId.value
                    overflowTarget = candidate.snapshot.to
                    break
                }
            }
            if (overflowRoot == "") {
                return
            }

            var removeIndex: Int64 = -1
            for (index in 0..hubMessages.size) {
                let state = hubMessages[index]
                if (state.rootSessionId.value == overflowRoot && state.snapshot.to == overflowTarget) {
                    if (removeIndex < 0) {
                        removeIndex = index
                    }
                    if (state.consumed) {
                        removeIndex = index
                        break
                    }
                }
            }
            if (removeIndex >= 0) {
                hubMessages.remove(at: removeIndex)
            } else {
                return
            }
        }
    }

    private func findJobLocked(key: ProductAsyncJobKey): ?ProductAsyncJobState {
        for (job in jobs where job.rootSessionId.value == key.rootSessionId.value &&
            job.sessionId.value == key.sessionId.value && job.id == key.id && job.instanceId == key.instanceId) {
            return Some(job)
        }
        None
    }

    private func hasJobIdLocked(id: String): Bool {
        for (job in jobs where job.id == id) { return true }
        false
    }

    private func jobListenerSinksLocked(): Array<ProductAsyncJobListener> { jobListeners.toArray() }

    private func emitJobEvent(
        kind: String,
        snapshot: ProductAsyncJobSnapshot,
        paidCapture172!: ?ProductJobCancelCapture172 = None<ProductJobCancelCapture172>
    ): Unit {
        let sinks: Array<ProductAsyncJobListener>
        lock.lock()
        try {
            match(paidCapture172){case Some(capture)=>capture.fundSinkSnapshot(jobListeners.size);case None=>()}
            sinks = jobListenerSinksLocked()
        } finally {
            lock.unlock()
        }
        let event = ProductAsyncJobEvent(kind, snapshot)
        for (sink in sinks) {
            sink.invoke180(event)
        }
    }

    private func selectJobKeys(
        sessionId: SessionId,
        ids: Array<String>
    ): Array<ProductAsyncJobKey> {
        lock.lock()
        try {
            let values = ArrayList<ProductAsyncJobKey>()
            for (job in jobs where job.sessionId.value == sessionId.value &&
                (ids.isEmpty() || containsTaskString(ids, job.id))) {
                values.add(job.key())
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    private func pluginJobPhysicalReturnedLocked111(job: ProductAsyncJobState): Bool {
        match (findSubagentLocked(job.agentId)) {
            case Some(state) =>
                if (state.pluginAdmission111.isSome() && state.pluginJobKey111.isSome()) {
                    let key = state.pluginJobKey111.getOrThrow()
                    if (key.rootSessionId.value == job.rootSessionId.value &&
                        key.sessionId.value == job.sessionId.value && key.id == job.id &&
                        key.instanceId == job.instanceId) { return pluginWorkersReturnedLocked111(state) }
                }
            case None => ()
        }
        // Old completed jobs no longer own the current incarnation. Replacing
        // it already required the old future set to have physically returned.
        true
    }

    private func jobSelectionByKeys(keys: Array<ProductAsyncJobKey>): ProductAsyncJobSelection {
        lock.lock()
        try {
            let values = ArrayList<ProductAsyncJobSnapshot>()
            var settledAndDelivered = false
            for (key in keys) {
                match (findJobLocked(key)) {
                    case Some(job) =>
                        values.add(job.snapshot())
                        if (job.status != "running" && job.settlementInjected && pluginJobPhysicalReturnedLocked111(job)) {
                            settledAndDelivered = true
                        }
                    case None => ()
                }
            }
            ProductAsyncJobSelection(values.toArray(), settledAndDelivered)
        } finally {
            lock.unlock()
        }
    }

    private func jobCanStart(key: ProductAsyncJobKey): Bool {
        lock.lock()
        try {
            match (findJobLocked(key)) {
                case Some(job) => job.status == "running"
                case None => false
            }
        } finally {
            lock.unlock()
        }
    }



    private func deliverBackgroundSnapshot(
        context: ToolInvocationContext,
        call: ToolCall,
        key: ProductAsyncJobKey,
        snapshot: ProductAsyncJobSnapshot,
        emitSettlement: Bool
    ): Unit {
        if (emitSettlement) {
            emitJobEvent("settled", snapshot)
            injectJobSettlement(key, waitForParent: true)
        } else if (snapshot.status == "recovery_required") {
            emitJobEvent("recovery_required", snapshot)
        }
        let _ = context
        let _ = call
    }

    private func prepareJobSettlementLocked(job: ProductAsyncJobState): Unit {
        if (job.settlementReceiptId == "") {
            job.settlementReceiptId = taskSettlementReceipt(job.sessionId.value, job.id, job.instanceId)
            job.settlementInjected = false
        }
    }

    private func replayPendingSettlements(): Unit {
        let keys = ArrayList<ProductAsyncJobKey>()
        var pruningRequired = false
        var receiptsDurable = true
        lock.lock()
        try {
            for (job in jobs where job.status != "running" && !job.settlementInjected) {
                prepareJobSettlementLocked(job)
                keys.add(job.key())
            }
            pruningRequired = jobs.size > 256
            // Receipts must be durable before any transcript append. One full
            // snapshot per root covers the whole recovery batch.
            if (!keys.isEmpty()) {
                match (persistAllTaskRootsLocked()) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        receiptsDurable = false
                        for (key in keys) {
                            match (findJobLocked(key)) {
                                case Some(job) => markJobPersistenceRecoveryLocked(job, error)
                                case None => ()
                            }
                        }
                }
            }
        } finally {
            lock.unlock()
        }
        if (!receiptsDurable) { return }
        if (keys.isEmpty() && !pruningRequired) { return }
        for (key in keys) {
            let _ = appendPreparedJobSettlement(key, waitForParent: false)
        }
        lock.lock()
        try {
            // Confirm every successfully appended receipt (and every explicit
            // collision state) in one second snapshot per root.
            match (persistAllTaskRootsLocked()) {
                case Result.Ok(_) => pruneJobsLocked()
                case Result.Err(error) =>
                    for (key in keys) {
                        match (findJobLocked(key)) {
                            case Some(job) => markJobPersistenceRecoveryLocked(job, error)
                            case None => ()
                        }
                    }
            }
        } finally {
            lock.unlock()
        }
    }

    private func injectJobSettlement(
        key: ProductAsyncJobKey,
        waitForParent!: Bool = true
    ): Unit {
        lock.lock()
        try {
            let job = match (findJobLocked(key)) {
                case Some(value) => value
                case None => return
            }
            if (job.status == "running" || job.settlementInjected) { return }
            prepareJobSettlementLocked(job)
            // Live completion keeps the narrow crash window explicit: receipt
            // first, transcript append second, acknowledgement last.
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    markJobPersistenceRecoveryLocked(job, error)
                    let _ = persistRootLocked(job.rootSessionId)
                    return
            }
        } finally {
            lock.unlock()
        }
        if (!appendPreparedJobSettlement(key, waitForParent: waitForParent)) { return }
        lock.lock()
        try {
            let job = match (findJobLocked(key)) {
                case Some(value) => value
                case None => return
            }
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => pruneJobsLocked()
                case Result.Err(error) =>
                    markJobPersistenceRecoveryLocked(job, error)
                    let _ = persistRootLocked(job.rootSessionId)
            }
        } finally {
            lock.unlock()
        }
    }

    // Appends one already-durable settlement and updates only its exact job
    // generation in memory. Callers choose live per-item persistence or the
    // recovery batch's final root snapshots.
    private func appendPreparedJobSettlement(
        key: ProductAsyncJobKey,
        waitForParent!: Bool
    ): Bool {
        let snapshot: ProductAsyncJobSnapshot
        let sessionId: SessionId
        let receiptId: String
        let parentToolCallId: String
        lock.lock()
        try {
            let job = match (findJobLocked(key)) {
                case Some(value) => value
                case None => return false
            }
            if (job.status == "running" || job.settlementInjected) { return false }
            snapshot = job.snapshot()
            sessionId = job.sessionId
            receiptId = job.settlementReceiptId
            parentToolCallId = job.parentToolCallId
        } finally {
            lock.unlock()
        }
        if (waitForParent && parentToolCallId != "" && !parentToolCallId.startsWith("cli-")) {
            awaitParentToolResult(sessionId, parentToolCallId)
        }
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(_) => return false
        }
        let payload = objectValue(
            [
                ValueField("type", textValue("async_result")),
                ValueField("job", asyncJobValue(snapshot))
            ]
        )
        let message = ModelMessage(
            ModelRole.User,
            [
                ModelBlock(
                    ModelBlockKind.Text,
                    text: "<async-result>" + encodeAgentValue(payload) + "</async-result>",
                    receiptId: receiptId
                )
            ]
        )
        var confirmed = false
        var verificationError = ""
        match (runtime.appendExternalMessageOnce(sessionId, receiptId, message)) {
            case Result.Err(appendError) => match (runtime.messages(sessionId)) {
                case Result.Ok(messages) =>
                    if (containsExactSettlementMessage(messages, message)) {
                        confirmed = true
                    } else {
                        verificationError = "recovery_required: cannot append async settlement; " +
                            appendError.message
                    }
                case Result.Err(error) =>
                    verificationError = "recovery_required: cannot verify the failed settlement append; " +
                        appendError.message + "; " + error.message
            }
            case Result.Ok(true) => confirmed = true
            case Result.Ok(false) => match (runtime.messages(sessionId)) {
                case Result.Ok(messages) =>
                    if (containsExactSettlementMessage(messages, message)) {
                        confirmed = true
                    } else {
                        verificationError = "recovery_required: settlement receipt collision; " +
                            "the existing receipt is bound to a different async result payload"
                    }
                case Result.Err(error) =>
                    verificationError = "recovery_required: cannot verify the existing settlement receipt; " +
                        error.message
            }
        }
        lock.lock()
        try {
            match (findJobLocked(key)) {
                case Some(job) =>
                    if (job.settlementReceiptId == receiptId && !job.settlementInjected) {
                        if (confirmed) {
                            job.settlementInjected = true
                        } else {
                            job.status = "recovery_required"
                            job.executing = false
                            job.updatedAt = nowMillis()
                            job.error = verificationError
                        }
                    }
                case None => ()
            }
        } finally {
            lock.unlock()
        }
        true
    }

    private func containsExactSettlementMessage(
        messages: Array<ModelMessage>,
        expected: ModelMessage
    ): Bool {
        for (message in messages) {
            if (message.role != expected.role || message.blocks.size != expected.blocks.size) { continue }
            var matches = true
            for (index in 0..message.blocks.size) {
                let actualBlock = message.blocks[index]
                let expectedBlock = expected.blocks[index]
                if (actualBlock.kind != expectedBlock.kind || actualBlock.text != expectedBlock.text ||
                    actualBlock.callId != expectedBlock.callId || actualBlock.name != expectedBlock.name ||
                    actualBlock.isError != expectedBlock.isError ||
                    encodeAgentValue(actualBlock.arguments) != encodeAgentValue(expectedBlock.arguments) ||
                    actualBlock.receiptId != expectedBlock.receiptId ||
                    !sameOpaqueProviderState(actualBlock.opaqueState, expectedBlock.opaqueState)) {
                    matches = false
                    break
                }
            }
            if (matches) { return true }
        }
        false
    }

    private func sameOpaqueProviderState(
        actual: ?OpaqueProviderState,
        expected: ?OpaqueProviderState
    ): Bool {
        match ((actual, expected)) {
            case (None, None) => true
            case (Some(actualValue), Some(expectedValue)) =>
                actualValue.providerId == expectedValue.providerId && actualValue.protocol == expectedValue.protocol &&
                    actualValue.itemId == expectedValue.itemId && actualValue.payload == expectedValue.payload &&
                    actualValue.replayRequired == expectedValue.replayRequired
            case _ => false
        }
    }

    private func awaitParentToolResult(
        sessionId: SessionId,
        callId: String
    ): Unit {
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(_) => return
        }
        for (_ in 0..500) {
            match (runtime.messages(sessionId)) {
                case Result.Ok(messages) =>
                    if (messagesContainToolResult(messages, callId)) {
                        return
                    }
                case Result.Err(_) => return
            }
            sleep(Duration.millisecond * 10)
        }
    }
}




class TaskSchemaValidation {
    let valid: Bool
    let error: String

    init(valid: Bool, error!: String = "") {
        this.valid = valid
        this.error = error
    }
}


public class ProductBundledAgentDefinition {
    public let name: String
    public let description: String
    public let prompt: String
    public let spawns: String
    public let model: String
    public let thinkingLevel: String

    public init(
        name: String,
        description: String,
        prompt: String,
        spawns!: String = "",
        model!: String = "",
        thinkingLevel!: String = ""
    ) {
        this.name = name
        this.description = description
        this.prompt = prompt
        this.spawns = spawns
        this.model = model
        this.thinkingLevel = thinkingLevel
    }
}

// Child runs have their own literal stable prefix. Reusing a parent's cache
// key after replacing its system prompt would associate different prefixes
// with one key. Shared context remains delimited, external turn data.
func productSubagentPrompt(role: ProductWorkflowRole, sharedContext: String): PromptBuild {
    let builder = PromptBuilder()
    builder.add(PromptSection(
        PromptSectionKind.Base,
        PromptTrust.System,
        PromptStability.Stable,
        role.source,
        role.version,
        role.prompt
    ))
    if (sharedContext.trimAscii() != "") {
        builder.add(PromptSection(
            PromptSectionKind.DynamicContext,
            PromptTrust.External,
            PromptStability.Turn,
            "delegated-task-context",
            "1",
            sharedContext.trimAscii()
        ))
    }
    builder.build()
}

func productSubagentRequest(
    base: AgentRunRequest,
    role: ProductWorkflowRole,
    capabilities: CapabilitySet,
    parentBudget: ExecutionBudget,
    sharedContext!: String = ""
): AgentRunRequest {
    let remaining = parentBudget.remainingCumulativeBudget()
    let promptBuild = productSubagentPrompt(role, sharedContext)
    AgentRunRequest(
        base.runId,
        base.sessionId,
        base.model,
        base.prompt,
        system: promptBuild.text,
        thinking: base.thinking,
        userRequestedThinking: base.requestedPolicy.userRequestedThinking,
        thinkingSource: base.requestedPolicy.thinkingSource,
        modelCapabilitiesSnapshot: Some(base.modelCapabilitiesSnapshot),
        resolverVersion: base.resolverVersion,
        interactions: base.interactions,
        capabilities: effectiveChildCapabilities(
            capabilities, role.ceiling, capabilities
        ),
        budget: ResourceBudget(
            maxInputTokens: base.budget.maxInputTokens,
            maxOutputTokens: min(role.limits.maxOutputTokens, base.budget.maxOutputTokens),
            requestOutputBudget: Some(RequestOutputBudget(min(role.limits.maxOutputTokens, base.budget.maxOutputTokens),
                minVisibleResponseTokens: base.budget.requestOutputBudget.minVisibleResponseTokens)),
            maxDrainModelRequests: base.budget.maxDrainModelRequests,
            maxDrainTurns: base.budget.maxDrainTurns,
            maxTotalInputTokens: productChildCumulativeLimit(
                base.budget.maxTotalInputTokens,
                parentBudget.maxTotalInputTokens,
                remaining.inputTokens
            ),
            maxTotalOutputTokens: productChildCumulativeLimit(
                base.budget.maxTotalOutputTokens,
                parentBudget.maxTotalOutputTokens,
                remaining.outputTokens
            ),
            maxModelRequests: min(role.limits.maxModelRequests, base.budget.maxModelRequests),
            maxTurns: min(role.limits.maxTurns, base.budget.maxTurns),
            maxToolCalls: min(role.limits.maxToolCalls, base.budget.maxToolCalls),
            maxWallMillis: productRequestedChildLimit(role.limits.maxWallMillis, base.budget.maxWallMillis),
            maxIdleMillis: min(role.limits.maxIdleMillis, base.budget.maxIdleMillis),
            maxChildren: min(role.limits.maxChildren, base.budget.maxChildren),
            maxDepth: min(role.limits.maxDepth, base.budget.maxDepth),
            maxConcurrentChildren: min(role.limits.maxConcurrentChildren, base.budget.maxConcurrentChildren),
            maxContextMessages: base.budget.maxContextMessages,
            maxConcurrentTools: base.budget.maxConcurrentTools,
            processLimits: base.budget.processLimits,
            maxCostMicros: productChildCumulativeLimit(
                base.budget.maxCostMicros,
                parentBudget.maxCostMicros,
                remaining.costMicros
            ),
            deadlineMillis: productChildDeadline(
                base.budget.deadlineMillis, parentBudget.deadlineMillis
            )
        ),
        approvalModeOverride: Option<ApprovalMode>.None,
        autoRetry: base.autoRetry,
        serviceTier: base.serviceTier,
        pricing: base.pricing,
        imageInputs: base.imageInputs,
        structuredOutput: base.structuredOutput,
        cachePolicy: base.cachePolicy,
        cacheKey: match (base.cachePolicy) {
            case ModelCachePolicy.StablePrefix => promptBuild.stablePrefixHash
            case ModelCachePolicy.Default => ""
        },
        parallelToolCalls: base.parallelToolCalls,
        toolContext: base.toolContext,
        contextSnapshot: base.contextSnapshot,
        initializeContext: base.initializeContext,
        contextWindow: base.contextWindow,
        providerSafetyMargin: base.providerSafetyMargin,
        executionLaneId: base.executionLaneId
    )
}

// Cap cumulative child usage by the headroom in its parent ledger.
// Zero remains the unbounded sentinel. Exhausted bounded parents receive
// a nonzero cap that admission rejects before child launch.
func productChildCumulativeLimit(
    requested: Int64,
    parentLimit: Int64,
    remaining: Int64
): Int64 {
    if (parentLimit == 0) { return requested }
    let capped = if (requested == 0) { remaining } else { min(requested, remaining) }
    if (capped == 0) { 1 } else { capped }
}
func productChildDeadline(requested: Int64, parent: Int64): Int64 {
    if (requested == 0) { return parent }
    if (parent == 0) { return requested }
    min(requested, parent)
}

// Zero in a Host wall-time budget is the existing unbounded sentinel. A positive
// plugin request can restrict that ceiling; it can never make it unbounded.
func productRequestedChildLimit(requested: Int64, host: Int64): Int64 {
    if (host == 0) { requested } else { min(requested, host) }
}


func parentModel(
    product: ProductRuntime,
    sessionId: SessionId
): String {
    match (product.sessionModel(sessionId)) {
        case Result.Ok(value) =>
            if (value == "") {
                product.model
            } else {
                value
            }
        case Result.Err(_) => product.model
    }
}

func updateSubagentProgress(
    state: ProductSubagentState,
    event: AgentEvent
): Bool {
    let code = match (event.detail.field("code")) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                value.text
            } else {
                ""
            }
        case None => ""
    }
    if (code == "model.completed") {
        state.requests += 1
        true
    } else if (code == "model.usage") {
        state.tokens += taskEventInteger(event.detail, "input_tokens") + taskEventInteger(event.detail, "output_tokens")
        true
    } else if (code == "tool.execution_started") {
        state.toolCount += 1
        state.currentTool = match (event.detail.field("name")) {
            case Some(value) =>
                if (value.unifiedKind == ValueKind.Text) {
                    value.text
                } else {
                    ""
                }
            case None => ""
        }
        true
    } else if (code == "tool.execution_completed") {
        state.currentTool = ""
        true
    } else {
        false
    }
}

func taskEventInteger(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Number) {
                try {
                    Int64.parse(field.asNumberText())
                } catch (_: Exception) {
                    0
                }
            } else {
                0
            }
        case None => 0
    }
}

func lastAssistantText(messages: Array<ModelMessage>): String {
    var result = ""
    for (message in messages where message.role == ModelRole.Assistant) {
        var text = ""
        for (block in message.blocks where block.kind == ModelBlockKind.Text) {
            text += block.text
        }
        if (text != "") {
            result = text
        }
    }
    result
}

func validateTaskSchema(
    schema: ?AgentValue,
    output: AgentValue
): TaskSchemaValidation {
    match (schema) {
        case None => TaskSchemaValidation(true)
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Boolean) {
                return if (value.asBool()) {
                    TaskSchemaValidation(true)
                } else {
                    TaskSchemaValidation(false, error: "schema rejects all values")
                }
            }
            if (value.unifiedKind == ValueKind.Text) {
                return TaskSchemaValidation(true)
            }
            validateTaskSchemaValue(value, output, "$")
    }
}

func validateTaskSchemaValue(
    schema: AgentValue,
    output: AgentValue,
    path: String
): TaskSchemaValidation {
    let expected = match (schema.field("type")) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                value.text
            } else {
                ""
            }
        case None => ""
    }
    if (expected != "" && !taskSchemaKindMatches(expected, output.unifiedKind)) {
        return TaskSchemaValidation(
            false,
            error: path + " must be " + expected
        )
    }
    match (schema.field("required")) {
        case Some(required) =>
            if (required.unifiedKind == ValueKind.List && output.unifiedKind == ValueKind.Object) {
                for (item in required.items where item.unifiedKind == ValueKind.Text && output.field(item.text).isNone()) {
                    return TaskSchemaValidation(
                        false,
                        error: path + "." + item.text + " is required"
                    )
                }
            }
        case None => ()
    }
    match (schema.field("properties")) {
        case Some(properties) =>
            if (properties.unifiedKind == ValueKind.Object && output.unifiedKind == ValueKind.Object) {
                for (field in properties.fields) {
                    match (output.field(field.name)) {
                        case Some(child) =>
                            let result = validateTaskSchemaValue(
                                field.value,
                                child,
                                path + "." + field.name
                            )
                            if (!result.valid) {
                                return result
                            }
                        case None => ()
                    }
                }
            }
        case None => ()
    }
    TaskSchemaValidation(true)
}

func taskSchemaKindMatches(expected: String, actual: ValueKind): Bool {
    match (expected) {
        case "object" => actual == ValueKind.Object
        case "array" => actual == ValueKind.List
        case "string" => actual == ValueKind.Text
        case "number" | "integer" => actual == ValueKind.Number
        case "boolean" => actual == ValueKind.Boolean
        case "null" => actual == ValueKind.Null
        case _ => true
    }
}


func asyncJobValue(job: ProductAsyncJobSnapshot): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("id", textValue(job.id)))
    fields.add(ValueField("agentId", textValue(job.agentId)))
    fields.add(ValueField("type", textValue(job.jobType)))
    fields.add(ValueField("status", textValue(job.status)))
    fields.add(ValueField("label", textValue(job.label)))
    fields.add(
        ValueField(
            "durationMs",
            integerValue(job.durationMillis)
        )
    )
    match (job.result) {
        case Some(value) => fields.add(ValueField("result", value))
        case None => ()
    }
    if (job.error != "") {
        fields.add(ValueField("error", textValue(job.error)))
    }
    objectValue(fields.toArray())
}



func hubMessageModelMessage(message: ProductHubMessageSnapshot): ModelMessage {
    ModelMessage(
        ModelRole.User,
        [
            ModelBlock(
                ModelBlockKind.Text,
                text: hubMessagePrompt(message)
            )
        ]
    )
}

func hubMessagePrompt(message: ProductHubMessageSnapshot): String {
    "<hub-message from=\"" + message.from + "\" id=\"" + message.id + "\">" + message.message + "</hub-message>"
}


func taskStringValues(values: Array<String>): AgentValue {
    let encoded = ArrayList<AgentValue>()
    for (value in values) {
        encoded.add(textValue(value))
    }
    listValue(encoded.toArray())
}

func containsTaskString(
    values: Array<String>,
    expected: String
): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func messagesContainToolResult(
    messages: Array<ModelMessage>,
    callId: String
): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult && block.callId == callId) {
            return true
        }
    }
    false
}



func emitToSinks(
    sinks: Array<ProductSubagentListener>,
    event: ProductSubagentEvent
): Unit {
    for (sink in sinks) {
        sink.invoke180(event)
    }
}

func nowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func addTaskRoot(values: ArrayList<String>, root: String): Unit {
    if (root == "") { return }
    for (value in values where value == root) { return }
    values.add(root)
}

func mergeProcessObservations201(
    callId: String,
    local: ToolResult,
    remote: ToolResult
): Result<ToolResult> {
    // Both actual input graphs were funded against the existing derived lease
    // before this helper. This combines DATA only; it grants no process access.
    let values = ArrayList<AgentValue>()
    let warnings = ArrayList<AgentValue>()
    for (result in [local, remote]) {
        let output = result.output
        if (!httpIntentExactFields(output, ["schema", "op", "facts"]) ||
            httpIntentText(output, "schema") != "axyndra.hub-process-observation/v1" ||
            httpIntentText(output, "op") != "ps") {
            return taskError<ToolResult>(
                "hub.process_list_invalid", "process supervisor returned an invalid observation envelope")
        }
        let facts = output.field("facts").getOrThrow()
        if (!httpIntentExactFields(facts, ["daemons", "recovery_warnings"])) {
            return taskError<ToolResult>(
                "hub.process_list_invalid", "process supervisor returned incomplete process facts")
        }
        let daemons = facts.field("daemons").getOrThrow()
        let recovery = facts.field("recovery_warnings").getOrThrow()
        if (daemons.unifiedKind != ValueKind.List || recovery.unifiedKind != ValueKind.List) {
            return taskError<ToolResult>(
                "hub.process_list_invalid", "process supervisor returned an invalid daemon or warning list")
        }
        for (warning in recovery.items) {
            if (warning.unifiedKind != ValueKind.Text) {
                return taskError<ToolResult>(
                    "hub.process_list_invalid", "process supervisor returned a non-text recovery warning")
            }
        }
        for (daemon in daemons.items) { values.add(daemon) }
        for (warning in recovery.items) { warnings.add(warning) }
    }
    Result.Ok(ToolResult(
        callId,
        objectValue([
            ValueField("schema", textValue("axyndra.hub-process-observation/v1")),
            ValueField("op", textValue("ps")),
            ValueField("facts", objectValue([
                ValueField("daemons", listValue(values.toArray())),
                ValueField("recovery_warnings", listValue(warnings.toArray()))
            ]))
        ]),
        isError: local.isError || remote.isError
    ))
}

func taskError<T>(
    code: String,
    message: String,
    fields!: Array<ErrorField> = []
): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            code,
            message,
            fields: fields
        )
    )
}

// Fixed paid counter only; no Source, state transition or completion claim.
class ProductJobSnapshotInvoice165 {
    var bytes: Int64 = 512
    var nodes: Int64 = 16
    init() {}
    func add(bytes: Int64, nodes: Int64): Unit {
        if (bytes < 0 || nodes < 0 || this.bytes > Int64.Max - bytes || this.nodes > Int64.Max - nodes) {
            throw LogicalJsonPayloadError("job snapshot retained SUM overflow") }
        this.bytes += bytes; this.nodes += nodes
    }
}
