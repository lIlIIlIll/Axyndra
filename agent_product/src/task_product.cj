package agent_product

import yjson_support.*

import yjson.*

import agent_client.*
import agent_core.*
import agent_domain.*
import agent_runtime.*
import model_adapters.*
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
        error!: String = ""
    ) {
        this.id = id
        this.index = index
        this.agent = agent
        this.agentSource = "bundled"
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
    let capabilities: CapabilitySet

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
        capabilities!: CapabilitySet = CapabilitySet(),
        startedAt!: Int64 = 0,
        status!: String = "running",
        lastUpdate!: Int64 = 0
    ) {
        this.id = id
        this.index = index
        this.agent = agent
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
            error: error
        )
    }
}

class ProductSubagentListener {
    let id: Int64
    let sink: ProductSubagentEventSink

    init(id: Int64, sink: ProductSubagentEventSink) {
        this.id = id
        this.sink = sink
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
    let runId: RunId
    let sections = ArrayList<ProductYieldSection>()
    var terminal: ?AgentValue = None
    var error: String = ""
    var useLastTurn = false

    init(runId: RunId) {
        this.runId = runId
    }
}

class ProductTaskSpec {
    let name: String
    let agent: String
    let task: String
    let effort: String
    let outputSchema: ?AgentValue
    let schemaMode: String

    init(
        name: String,
        agent: String,
        task: String,
        effort: String,
        outputSchema: ?AgentValue,
        schemaMode: String
    ) {
        this.name = name
        this.agent = agent
        this.task = task
        this.effort = effort
        this.outputSchema = outputSchema
        this.schemaMode = schemaMode
    }
}

class ProductTaskBatch {
    let context: String
    let specs: Array<ProductTaskSpec>
    let batch: Bool

    init(
        context: String,
        specs: Array<ProductTaskSpec>,
        batch: Bool
    ) {
        this.context = context
        this.specs = specs
        this.batch = batch
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

class ProductTaskResult {
    let snapshot: ProductSubagentSnapshot
    let exitCode: Int64
    let output: AgentValue
    let stderr: String
    let schemaStatus: String
    let schemaError: String
    let schemaMode: String

    init(
        snapshot: ProductSubagentSnapshot,
        exitCode: Int64,
        output: AgentValue,
        stderr!: String = "",
        schemaStatus!: String = "unavailable",
        schemaError!: String = "",
        schemaMode!: String = "permissive"
    ) {
        this.snapshot = snapshot
        this.exitCode = exitCode
        this.output = output
        this.stderr = stderr
        this.schemaStatus = schemaStatus
        this.schemaError = schemaError
        this.schemaMode = schemaMode
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

type ProductBashJobAction = (OperationId) -> Result<ToolResult>

class ProductAsyncJobListener {
    let id: Int64
    let sink: ProductAsyncJobEventSink

    init(id: Int64, sink: ProductAsyncJobEventSink) {
        this.id = id
        this.sink = sink
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
    var consumed = false

    init(
        snapshot: ProductHubMessageSnapshot,
        targetSessionId: SessionId,
        rootSessionId: SessionId,
        waitCallId!: String = "",
        reviveTarget!: Bool = false,
        consumed!: Bool = false
    ) {
        this.snapshot = snapshot
        this.targetSessionId = targetSessionId
        this.rootSessionId = rootSessionId
        this.waitCallId = waitCallId
        this.reviveTarget = reviveTarget
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
    private var processBroker: ?ProductProcessBroker = None
    private var taskPersistence: ?ProductTaskPersistence = None
    private let stateRevisions = HashMap<String, Int64>()
    private let childBudgetPools = HashMap<String, ChildBudgetPool>()
    private let childBudgetOrder = ArrayList<String>()
    private let childBudgetLeases = HashMap<String, ChildBudgetLease>()
    private let childUsage = HashMap<String, ExecutionUsage>()
    private let ownedWorkers = ArrayList<Future<Unit>>()
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

    func attach(value: ProductRuntime, persistence: ProductTaskPersistence): Unit {
        var restored = false
        lock.lock()
        try {
            product = Some(value)
            processSupervisor = Some(ProductProcessSupervisor(
                value.workspace,
                sandboxEnabled: value.directProcessSandboxEnabled(),
                allowUnsafeTestBypass: allowUnsafeDirectLaunchForTests
            ))
            processBroker = Some(ProductProcessBroker(value.stateRoot, value.workspace.rootPath()))
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
            ownedWorkers.add(spawn { action() })
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func close(): Result<Unit> {
        let targets = ArrayList<ProductSubagentSnapshot>()
        let jobTargets = ArrayList<ProductAsyncJobKey>()
        let workers: Array<Future<Unit>>
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
            supervisor = processSupervisor
            runtime = product
        } finally {
            lock.unlock()
        }
        match (runtime) {
            case Some(value) =>
                for (target in targets) { let _ = value.client.cancel(target.runId) }
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

    func recoveryWarningsFor(context: ToolInvocationContext): Array<String> {
        lock.lock()
        try {
            let root = hubIdentityLocked(context).rootSessionId.value
            let values = ArrayList<String>()
            for (warning in recoveryWarnings where warning.rootSessionId == root || warning.rootSessionId == "unknown") {
                values.add(warning.text())
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
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
        match (sendHubMessage(
            ToolInvocationContext(
                RunId("tui-hub-" + suffix),
                rootSessionId,
                CapabilitySet()
            ),
            ToolCall(
                "tui-hub-" + suffix,
                "hub",
                objectValue([])
            ),
            subagentId,
            text,
            "",
            false,
            0
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
            pendingRequest = state.pendingRequest
            pendingApproval = state.pendingApproval
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
        let _ = tasks.transition(TaskId(subagentId), TaskStatus.Running)
        match (runtime.client.decide(
            request,
            approval,
            decision,
            {event => recordChildEvent(subagentId, event)}
        )) {
            case Result.Err(error) =>
                let _ = tasks.transition(TaskId(subagentId), TaskStatus.Blocked)
                Result.Err(error)
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                applyRunSnapshot(subagentId, snapshot)
                let _ = tasks.transition(TaskId(subagentId), TaskStatus.Completed)
                let _ = finishSubagent(subagentId, "completed")
                Result.Ok(())
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, next)) =>
                applyRunSnapshot(subagentId, snapshot)
                let _ = markSubagentAwaitingApproval(subagentId, request, next)
                let _ = tasks.transition(TaskId(subagentId), TaskStatus.Blocked)
                Result.Ok(())
        }
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

    public func executeTask(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let batch = match (parseProductTaskBatch(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Ok(
                ToolResult(
                    call.callId,
                    objectValue(
                        [
                            ValueField("results", listValue([])),
                            ValueField("error", textValue(error.message))
                        ]
                    ),
                    isError: true
                )
            )
        }
        if (batch.batch) {
            return executeTaskBatch(context, call, batch)
        }
        let spec = batch.specs[0]
        if (asyncEnabled && !productAgentBlocks(spec.agent)) {
            return startBackgroundTask(
                context,
                call,
                spec,
                sharedContext: batch.context
            )
        }
        let result = match (runTask(
            context,
            call,
            spec,
            sharedContext: batch.context
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Ok(
                ToolResult(
                    call.callId,
                    objectValue(
                        [
                            ValueField("results", listValue([])),
                            ValueField("error", textValue(error.message))
                        ]
                    ),
                    isError: true
                )
            )
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("results", listValue([productTaskResultValue(result)])),
                        ValueField("totalDurationMs", integerValue(result.snapshot.durationMillis))
                    ]
                ),
                isError: result.exitCode != 0
            )
        )
    }

    private func executeTaskBatch(
        context: ToolInvocationContext,
        call: ToolCall,
        batch: ProductTaskBatch
    ): Result<ToolResult> {
        let started = nowMillis()
        let inline = ArrayList<ProductTaskSpec>()
        let progress = ArrayList<AgentValue>()
        let asyncIds = ArrayList<String>()
        if (asyncEnabled) {
            for (spec in batch.specs) {
                if (productAgentBlocks(spec.agent)) {
                    inline.add(spec)
                } else {
                    let launched = match (startBackgroundTask(
                        context,
                        call,
                        spec,
                        sharedContext: batch.context
                    )) {
                        case Result.Ok(value) => value
                        case Result.Err(error) => return Result.Err(error)
                    }
                    let rows = launched.output.field("progress").getOrThrow().items
                    for (row in rows) {
                        progress.add(row)
                        asyncIds.add(row.field("id").getOrThrow().text)
                    }
                }
            }
        } else {
            inline.add(all: batch.specs)
        }
        let inlineValues = ArrayList<AgentValue>()
        var failed = false
        let inlineResults = runInlineBatch(
            context,
            call,
            inline.toArray(),
            batch.context
        )
        for (result in inlineResults) {
            match (result) {
                case Result.Ok(value) =>
                    inlineValues.add(productTaskResultValue(value))
                    if (value.exitCode != 0) {
                        failed = true
                    }
                case Result.Err(error) =>
                    failed = true
                    inlineValues.add(
                        objectValue(
                            [
                                ValueField("exitCode", integerValue(1)),
                                ValueField("error", textValue(error.message))
                            ]
                        )
                    )
            }
        }
        let fields = ArrayList<ValueField>()
        fields.add(
            ValueField(
                "results",
                listValue(inlineValues.toArray())
            )
        )
        fields.add(
            ValueField(
                "totalDurationMs",
                integerValue(max(0, nowMillis() - started))
            )
        )
        fields.add(
            ValueField(
                "progress",
                listValue(progress.toArray())
            )
        )
        if (!asyncIds.isEmpty()) {
            fields.add(
                ValueField(
                    "async",
                    objectValue(
                        [
                            ValueField("state", textValue("running")),
                            ValueField("jobId", textValue(asyncIds[0])),
                            ValueField("type", textValue("task")),
                            ValueField(
                                "jobIds",
                                taskStringValues(asyncIds.toArray())
                            )
                        ]
                    )
                )
            )
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(fields.toArray()),
                isError: failed
            )
        )
    }

    private func runInlineBatch(
        context: ToolInvocationContext,
        call: ToolCall,
        specs: Array<ProductTaskSpec>,
        sharedContext: String
    ): Array<Result<ProductTaskResult>> {
        let results = ArrayList<Result<ProductTaskResult>>()
        var start: Int64 = 0
        while (start < specs.size) {
            let end = min(specs.size, start + 4)
            let futures = ArrayList<Future<Result<ProductTaskResult>>>()
            for (index in start..end) {
                let spec = specs[index]
                futures.add(spawn {
                    runTask(
                        context,
                        call,
                        spec,
                        sharedContext: sharedContext
                    )
                })
            }
            for (future in futures) {
                results.add(future.get())
            }
            start = end
        }
        results.toArray()
    }

    public func jobsFor(sessionId: SessionId): Array<ProductAsyncJobSnapshot> {
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

    func startBashJob(
        context: ToolInvocationContext,
        call: ToolCall,
        command: String,
        action: ProductBashJobAction
    ): Result<ToolResult> {
        let job: ProductAsyncJobState
        let key: ProductAsyncJobKey
        let operationId: OperationId
        lock.lock()
        try {
            let previousJobs = jobs.toArray()
            let previousJobCounter = jobCounter
            var running: Int64 = 0
            for (value in jobs where value.status == "running") {
                running += 1
            }
            if (running >= 15) {
                return taskError<ToolResult>(
                    "async.capacity",
                    "background job limit reached (15)"
                )
            }
            jobCounter += 1
            let id = "bash-" + nowMillis().toString() + "-" + jobCounter.toString()
            operationId = OperationId("bash-job-" + id)
            job = ProductAsyncJobState(
                id,
                "",
                "bash",
                command,
                context.sessionId,
                hubIdentityLocked(context).rootSessionId,
                context.runId,
                jobCounter,
                parentToolCallId: call.callId,
                operationId: operationId.value
            )
            jobs.add(job)
            key = job.key()
            pruneJobsLocked()
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    jobs.clear()
                    jobs.add(all: previousJobs)
                    jobCounter = previousJobCounter
                    rememberTaskPersistenceFailureLocked(job.rootSessionId, error)
                    return Result.Err(error)
            }
            // The executing marker is durable before the shell action can
            // perform any external side effect.
            job.executing = true
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    markJobPersistenceRecoveryLocked(job, error)
                    let _ = persistRootLocked(job.rootSessionId)
                    return Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
        emitJobEvent("started", job.snapshot())
        match (startOwnedWorker({ =>
            if (jobCanStart(key)) {
                finishBackgroundBash(
                    context,
                    call,
                    key,
                    action(operationId)
                )
            }
        })) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("jobId", textValue(job.id)),
                        ValueField("status", textValue("running")),
                        ValueField("type", textValue("bash")),
                        ValueField("command", textValue(command)),
                        ValueField(
                            "async",
                            objectValue(
                                [
                                    ValueField("state", textValue("running")),
                                    ValueField("jobId", textValue(job.id)),
                                    ValueField("type", textValue("bash"))
                                ]
                            )
                        )
                    ]
                )
            )
        )
    }

    func sendHubMessage(
        context: ToolInvocationContext,
        call: ToolCall,
        to: String,
        message: String,
        replyTo: String,
        awaitReply: Bool,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        if (awaitReply && to == "all") {
            return taskError<ToolResult>(
                "hub.await_broadcast",
                "hub send await:true cannot target all"
            )
        }
        let deliveries = ArrayList<ProductHubMessageState>()
        lock.lock()
        try {
            let previousMessages = hubMessages.toArray()
            let previousMessageCounter = messageCounter
            let sender = hubIdentityLocked(context)
            let targets = hubTargetsLocked(sender, to)
            if (targets.isEmpty()) {
                return taskError<ToolResult>(
                    "hub.peer_not_found",
                    "unknown or unavailable hub peer: " + to
                )
            }
            for (target in targets) {
                if (target.id == sender.id) {
                    return taskError<ToolResult>(
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
                    reviveSubagent(delivery.snapshot.to, delivery.snapshot)
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
        let receipts = ArrayList<AgentValue>()
        for (delivery in deliveries) {
            receipts.add(
                objectValue(
                    [
                        ValueField("id", textValue(delivery.snapshot.id)),
                        ValueField("to", textValue(delivery.snapshot.to)),
                        ValueField("delivered", boolValue(true))
                    ]
                )
            )
        }
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("op", textValue("send")))
        fields.add(
            ValueField(
                "from",
                textValue(deliveries[0].snapshot.from)
            )
        )
        fields.add(
            ValueField(
                "receipts",
                listValue(receipts.toArray())
            )
        )
        if (awaitReply) {
            let waited = match (waitForHubMessage(
                context,
                to,
                timeoutMillis
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            fields.add(
                ValueField(
                    "waited",
                    match (waited) {
                        case Some(value) => hubMessageValue(value)
                        case None => nullValue()
                    }
                )
            )
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(fields.toArray())
            )
        )
    }

    func deliverHubMessagesAfterParentResult(
        sessionId: SessionId,
        parentToolCallId: String
    ): Result<Unit> {
        let pending = ArrayList<ProductHubMessageSnapshot>()
        lock.lock()
        try {
            for (state in hubMessages where
                state.targetSessionId.value == sessionId.value &&
                state.waitCallId == parentToolCallId) {
                pending.add(state.snapshot)
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
                "hub-delivery:" + message.id,
                hubMessageModelMessage(message),
                source: "hub_delivery"
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }

    func hubInbox(
        context: ToolInvocationContext,
        call: ToolCall,
        peek: Bool
    ): Result<ToolResult> {
        let messages = match (takeHubMessages(context, "", peek)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("op", textValue("inbox")),
                        ValueField("inbox", hubMessagesValue(messages)),
                        ValueField("peek", boolValue(peek))
                    ]
                )
            )
        )
    }

    func hubMessageWait(
        context: ToolInvocationContext,
        call: ToolCall,
        from: String,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        let waited = match (waitForHubMessage(
            context,
            from,
            timeoutMillis
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("op", textValue("wait")),
                        ValueField(
                            "waited",
                            match (waited) {
                                case Some(value) => hubMessageValue(value)
                                case None => nullValue()
                            }
                        )
                    ]
                )
            )
        )
    }

    func hubPeers(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let peers = ArrayList<AgentValue>()
        lock.lock()
        try {
            let caller = hubIdentityLocked(context)
            peers.add(
                objectValue(
                    [
                        ValueField("id", textValue("Main")),
                        ValueField("kind", textValue("main")),
                        ValueField(
                            "status",
                            textValue(if (caller.id == "Main") {
                                "running"
                            } else {
                                "idle"
                            })
                        )
                    ]
                )
            )
            for (record in records where record.parentSessionId.value == caller.rootSessionId.value) {
                peers.add(
                    objectValue(
                        [
                            ValueField("id", textValue(record.id)),
                            ValueField("kind", textValue("sub")),
                            ValueField("agent", textValue(record.agent)),
                            ValueField("status", textValue(record.status)),
                            ValueField(
                                "activity",
                                textValue(record.currentTool)
                            )
                        ]
                    )
                )
            }
        } finally {
            lock.unlock()
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("op", textValue("list")),
                        ValueField("peers", listValue(peers.toArray()))
                    ]
                )
            )
        )
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

    private func cancelJobKeys(
        runtime: ProductRuntime,
        keys: Array<ProductAsyncJobKey>
    ): Unit {
        let targets = ArrayList<ProductAsyncJobTarget>()
        lock.lock()
        try {
            for (key in keys) {
                match (findJobLocked(key)) {
                    case Some(job) =>
                        if (job.status == "running") {
                            job.status = "cancelled"
                            job.error = "cancelled by hub"
                            job.updatedAt = nowMillis()
                            prepareJobSettlementLocked(job)
                        }
                        targets.add(ProductAsyncJobTarget(key, job.snapshot()))
                    case None => ()
                }
            }
            match (persistAllTaskRootsLocked()) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
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
        }
        for (target in targets where target.snapshot.status == "cancelled") {
            let snapshot = target.snapshot
            if (snapshot.jobType == "bash") {
                if (snapshot.operationId != "" && snapshot.executing) {
                    cancelBashOperation(runtime, snapshot.operationId)
                }
            } else {
                let child = lockAndFindSubagent(target.key.rootSessionId, snapshot.agentId, "")
                match (child) {
                    case Some(childSnapshot) =>
                        let _ = runtime.client.cancel(childSnapshot.runId)
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
            emitJobEvent("cancelled", snapshot)
            injectJobSettlement(target.key, waitForParent: true)
        }
    }

    private func startBackgroundTask(
        context: ToolInvocationContext,
        call: ToolCall,
        spec: ProductTaskSpec,
        sharedContext!: String = ""
    ): Result<ToolResult> {
        let reservation: ProductSubagentReservation
        let job: ProductAsyncJobState
        let key: ProductAsyncJobKey
        lock.lock()
        try {
            let previousJobs = jobs.toArray()
            let previousJobCounter = jobCounter
            let previousSubagentCounter = subagentCounter
            reservation = reserveSubagentLocked(spec.name)
            jobCounter += 1
            job = ProductAsyncJobState(
                reservation.id,
                reservation.id,
                "task",
                spec.task,
                context.sessionId,
                hubIdentityLocked(context).rootSessionId,
                context.runId,
                jobCounter,
                parentToolCallId: call.callId
            )
            jobs.add(job)
            key = job.key()
            pruneJobsLocked()
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    jobs.clear()
                    jobs.add(all: previousJobs)
                    jobCounter = previousJobCounter
                    subagentCounter = previousSubagentCounter
                    rememberTaskPersistenceFailureLocked(job.rootSessionId, error)
                    return Result.Err(error)
            }
            job.executing = true
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    markJobPersistenceRecoveryLocked(job, error)
                    let _ = persistRootLocked(job.rootSessionId)
                    return Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
        emitJobEvent("started", job.snapshot())
        match (startOwnedWorker({ =>
            if (jobCanStart(key)) {
                let result = runTask(
                    context,
                    call,
                    spec,
                    sharedContext: sharedContext,
                    reservation: Some(reservation),
                    jobKey: Some(key)
                )
                finishBackgroundTask(context, call, key, result)
            }
        })) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("results", listValue([])),
                        ValueField("totalDurationMs", integerValue(0)),
                        ValueField("progress", listValue([asyncJobValue(job.snapshot())])),
                        ValueField(
                            "async",
                            objectValue(
                                [
                                    ValueField("state", textValue("running")),
                                    ValueField("jobId", textValue(job.id)),
                                    ValueField("type", textValue("task"))
                                ]
                            )
                        )
                    ]
                )
            )
        )
    }

    public func submitYield(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        lock.lock()
        try {
            let state = findYieldLocked(context.runId)
            if (state.isNone()) {
                return Result.Ok(
                    ToolResult(
                        call.callId,
                        objectValue(
                            [
                                ValueField(
                                    "error",
                                    textValue("yield is only available inside a " + "delegated task")
                                )
                            ]
                        ),
                        isError: true
                    )
                )
            }
            let result = match (call.arguments.field("result")) {
                case Some(value) =>
                    if (value.unifiedKind != ValueKind.Object) {
                        return yieldArgumentError(call, "result must be an object")
                    }
                    value
                case None => return yieldArgumentError(call, "result is required")
            }
            let typeValue = call.arguments.field("type")
            let data = result.field("data")
            let error = result.field("error")
            if (data.isSome() && error.isSome()) {
                return yieldArgumentError(
                    call,
                    "result cannot contain both data and error"
                )
            }
            let target = state.getOrThrow()
            match (error) {
                case Some(value) =>
                    if (value.unifiedKind != ValueKind.Text || value.text.trimAscii() == "") {
                        return yieldArgumentError(
                            call,
                            "result.error must be a non-empty string"
                        )
                    }
                    target.error = value.text
                case None => match (data) {
                    case Some(value) => match (yieldLabels(typeValue)) {
                        case Result.Ok(labels) =>
                            if (labels.isEmpty()) {
                                target.terminal = Some(value)
                            } else if (typeValue.getOrThrow().unifiedKind == ValueKind.List) {
                                target.sections.add(ProductYieldSection(labels, value))
                            } else {
                                target.terminal = Some(value)
                            }
                        case Result.Err(error) => return Result.Err(error)
                    }
                    case None => match (typeValue) {
                        case Some(value) =>
                            if (value.unifiedKind == ValueKind.Text && value.text.trimAscii() != "") {
                                target.useLastTurn = true
                            } else {
                                return yieldArgumentError(
                                    call,
                                    "empty result requires a " + "terminal string type"
                                )
                            }
                        case None => return yieldArgumentError(
                            call,
                            "result requires data or error"
                        )
                    }
                }
            }
            Result.Ok(
                ToolResult(
                    call.callId,
                    objectValue(
                        [
                            ValueField("accepted", boolValue(true)),
                            ValueField(
                                "status",
                                textValue(if (target.error == "") {
                                    "success"
                                } else {
                                    "aborted"
                                })
                            )
                        ]
                    )
                )
            )
        } finally {
            lock.unlock()
        }
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
            for (record in records where record.parentRunId.value == parentRunId.value && (record.status == "running" ||
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

    private func runTask(
        context: ToolInvocationContext,
        call: ToolCall,
        spec: ProductTaskSpec,
        sharedContext!: String = "",
        reservation!: ?ProductSubagentReservation = None,
        jobKey!: ?ProductAsyncJobKey = None
    ): Result<ProductTaskResult> {
        let runtime = match (attachedProduct()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let parentDepth = depthForRun(context.runId)
        let depth = parentDepth + 1
        let base = runtime.request(
            spec.task,
            modelOverride: parentModel(runtime, context.sessionId),
            thinking: taskThinking(spec.effort)
        )
        let childCapabilities = effectiveChildCapabilities(
            context.capabilities,
            productAgentCapabilityCeiling(spec.agent),
            context.capabilities
        )
        let child = productSubagentRequest(
            base,
            spec.agent,
            childCapabilities,
            sharedContext: sharedContext
        )
        let state = match (createSubagentState(
            runtime,
            context,
            call,
            spec,
            child,
            depth,
            reservation: reservation
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (reserveChildBudget(context, state.id, executionBudgetFrom(child.budget))) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = finishSubagent(state.id, "failed", error: error.message)
                return Result.Err(error)
        }
        let backgroundCanStart = match (jobKey) {
            case Some(value) => jobCanStart(value)
            case None => true
        }
        if (subagentStatus(state.id) == "cancelled" || !backgroundCanStart) {
            let snapshot = finishSubagent(state.id, "cancelled")
            return Result.Ok(
                ProductTaskResult(
                    snapshot,
                    1,
                    textValue(""),
                    stderr: "subagent was cancelled before launch"
                )
            )
        }
        if (depth > child.budget.maxDepth) {
            finishSubagent(state.id, "failed")
            return taskError<ProductTaskResult>(
                "subagent.budget_exceeded",
                "subagent resource budget exceeded",
                fields: [ErrorField("resource", "depth")]
            )
        }
        let taskId = TaskId(state.id)
        match (tasks.create(taskId, spec.task)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                finishSubagent(state.id, "failed")
                return Result.Err(error)
        }
        let _ = tasks.transition(
            taskId,
            TaskStatus.Running,
            runId: Some(child.runId)
        )
        if (subagentStatus(state.id) == "cancelled") {
            let snapshot = subagentSnapshot(state.id)
            return Result.Ok(
                ProductTaskResult(
                    snapshot,
                    1,
                    textValue(""),
                    stderr: "subagent was cancelled before launch"
                )
            )
        }
        // ChildBudgetPool already owns child count, concurrency and aggregate
        // usage reservations. Launch the isolated child Run directly through
        // the same typed AgentClient as the parent instead of layering a
        // second coordinator with a duplicate budget ledger.
        let launched = runtime.client.start(
            child,
            {event => recordChildEvent(state.id, event)}
        )
        let messages: Array<ModelMessage> = match (runtime.messages(child.sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => []
        }
        let lastText = lastAssistantText(messages)
        match (launched) {
            case Result.Err(error) =>
                if (subagentStatus(state.id) == "cancelled") {
                    Result.Ok(
                        ProductTaskResult(
                            subagentSnapshot(state.id),
                            1,
                            textValue(""),
                            stderr: "subagent was cancelled"
                        )
                    )
                } else {
                    let _ = tasks.transition(taskId, TaskStatus.Failed)
                    let snapshot = finishSubagent(
                        state.id,
                        "failed",
                        error: error.message
                    )
                    Result.Ok(
                        ProductTaskResult(
                            snapshot,
                            1,
                            textValue(""),
                            stderr: error.message
                        )
                    )
                }
            case Result.Ok(outcome) => match (reviewSubagentOutcome(
                runtime,
                state.id,
                child,
                outcome
            )) {
                case Result.Err(error) =>
                    let _ = tasks.transition(taskId, TaskStatus.Failed)
                    let snapshot = finishSubagent(state.id, "failed", error: error.message)
                    Result.Ok(
                        ProductTaskResult(
                            snapshot,
                            1,
                            textValue(""),
                            stderr: error.message
                        )
                    )
                case Result.Ok(outcome) => match (outcome) {
                    case AgentRunOutcome.AwaitingApproval(snapshot, approval) =>
                        let _ = tasks.transition(taskId, TaskStatus.Blocked)
                        applyRunSnapshot(state.id, snapshot)
                        let blockedSnapshot = markSubagentAwaitingApproval(
                            state.id,
                            child,
                            approval
                        )
                        Result.Ok(
                            ProductTaskResult(
                                blockedSnapshot,
                                1,
                                textValue(""),
                                stderr: "subagent is awaiting approval"
                            )
                        )
                    case AgentRunOutcome.Completed(snapshot) =>
                        applyRunSnapshot(state.id, snapshot)
                        finalizeCompletedTask(
                            taskId,
                            state.id,
                            spec,
                            lastText
                        )
                }
            }
        }
    }

    private func finalizeCompletedTask(
        taskId: TaskId,
        subagentId: String,
        spec: ProductTaskSpec,
        lastText: String
    ): Result<ProductTaskResult> {
        let yielded = takeYield(subagentId)
        if (yielded.error != "") {
            let _ = tasks.transition(taskId, TaskStatus.Failed)
            let snapshot = finishSubagent(
                subagentId,
                "failed",
                error: yielded.error
            )
            return Result.Ok(
                ProductTaskResult(
                    snapshot,
                    1,
                    textValue(""),
                    stderr: yielded.error
                )
            )
        }
        let output = yieldedOutput(yielded, lastText)
        let validation = validateTaskSchema(spec.outputSchema, output)
        if (!validation.valid && spec.schemaMode == "strict") {
            let _ = tasks.transition(taskId, TaskStatus.Failed)
            let snapshot = finishSubagent(
                subagentId,
                "failed",
                error: validation.error
            )
            return Result.Ok(
                ProductTaskResult(
                    snapshot,
                    1,
                    output,
                    stderr: validation.error,
                    schemaStatus: "invalid",
                    schemaError: validation.error,
                    schemaMode: spec.schemaMode
                )
            )
        }
        let _ = tasks.transition(taskId, TaskStatus.Completed)
        let snapshot = finishSubagent(subagentId, "completed")
        Result.Ok(
            ProductTaskResult(
                snapshot,
                0,
                output,
                schemaStatus: if (spec.outputSchema.isSome()) {
                    if (validation.valid) {
                        "valid"
                    } else {
                        "invalid"
                    }
                } else {
                    "unavailable"
                },
                schemaError: validation.error,
                schemaMode: spec.schemaMode
            )
        )
    }

    private func createSubagentState(
        runtime: ProductRuntime,
        context: ToolInvocationContext,
        call: ToolCall,
        spec: ProductTaskSpec,
        child: AgentRunRequest,
        depth: Int64,
        reservation!: ?ProductSubagentReservation = None
    ): Result<ProductSubagentState> {
        lock.lock()
        let state: ProductSubagentState
        let sinks: Array<ProductSubagentEventSink>
        try {
            let previousRecords = records.toArray()
            let previousYields = yields.toArray()
            let previousSubagentCounter = subagentCounter
            let allocated = match (reservation) {
                case Some(value) => value
                case None => reserveSubagentLocked(spec.name)
            }
            state = ProductSubagentState(
                allocated.id,
                allocated.index,
                spec.agent,
                productAgentDescription(spec.agent),
                spec.task,
                spec.task,
                child.sessionId,
                runtime.sessionReference(child.sessionId),
                child.runId,
                context.runId,
                context.sessionId,
                call.callId,
                depth,
                capabilities: context.capabilities
            )
            state.pendingRequest = Some(child)
            records.add(state)
            yields.add(ProductYieldState(child.runId))
            pruneSubagentsLocked()
            match (persistRootLocked(context.sessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    records.clear()
                    records.add(all: previousRecords)
                    yields.clear()
                    yields.add(all: previousYields)
                    subagentCounter = previousSubagentCounter
                    rememberTaskPersistenceFailureLocked(context.sessionId, error)
                    return Result.Err(error)
            }
            sinks = listenerSinksLocked()
        } finally {
            lock.unlock()
        }
        emitToSinks(
            sinks,
            ProductSubagentEvent("lifecycle", state.snapshot())
        )
        Result.Ok(state)
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
        let sinks: Array<ProductSubagentEventSink>
        try {
            let state = findSubagentLocked(id)
            match (state) {
                case Some(value) =>
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
        let sinks: Array<ProductSubagentEventSink>
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
        message: ProductHubMessageSnapshot
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
        let childCapabilities = capabilitiesForSubagent(id)
        let base = runtime.request(
            hubMessagePrompt(message),
            sessionId: Some(state.sessionId),
            modelOverride: runtime.model
        )
        let request = productSubagentRequest(
            base,
            state.agent,
            childCapabilities
        )
        let sinks: Array<ProductSubagentEventSink>
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
                return
            }
            if (current.status == "recovery_required") {
                return
            }
            current.runId = request.runId
            current.status = "running"
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
                    let _ = persistRootLocked(current.parentSessionId)
                    return
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
        match (runtime.client.start(
            request,
            {event => recordChildEvent(id, event)}
        )) {
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
                case Result.Err(_) =>
                    if (subagentStatus(id) != "cancelled") {
                        let _ = finishSubagent(id, "failed")
                    }
            }
            case Result.Err(_) =>
                if (subagentStatus(id) != "cancelled") {
                    let _ = finishSubagent(id, "failed")
                }
        }
    }

    private func reviewSubagentOutcome(
        runtime: ProductRuntime,
        id: String,
        request: AgentRunRequest,
        initial: AgentRunOutcome
    ): Result<AgentRunOutcome> {
        var outcome = initial
        while (true) {
            match (outcome) {
                case AgentRunOutcome.Completed(_) => return Result.Ok(outcome)
                case AgentRunOutcome.AwaitingApproval(snapshot, approval) =>
                    if (runtime.approvalSettings.mode == ApprovalRoutingMode.Manual) {
                        return Result.Ok(outcome)
                    }
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
        id: String,
        status: String,
        error!: String = ""
    ): ProductSubagentSnapshot {
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
        } else {
            status
        }
        let effectiveError = match (budgetSettlementError) {
            case Some(value) => "recovery_required: child budget settlement failed: " + value.message
            case None => error
        }
        lock.lock()
        let snapshot: ProductSubagentSnapshot
        let sinks: Array<ProductSubagentEventSink>
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
            snapshot = state.snapshot()
            sinks = listenerSinksLocked()
        } finally {
            lock.unlock()
        }
        emitToSinks(
            sinks,
            ProductSubagentEvent("lifecycle", snapshot)
        )
        snapshot
    }

    private func reserveChildBudget(
        context: ToolInvocationContext,
        childId: String,
        child: ExecutionBudget
    ): Result<Unit> {
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
                if (pool.isNone() || pool.getOrThrow().snapshot().activeReservations == 0) {
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
        let lease: ?ChildBudgetLease
        let usage: ExecutionUsage
        lock.lock()
        try {
            lease = childBudgetLeases.get(childId)
            usage = match (childUsage.get(childId)) {
                case Some(value) => value
                case None => ExecutionUsage()
            }
        } finally {
            lock.unlock()
        }
        let selected = match (lease) {
            case Some(value) => value
            // A restored pre-vNext child has no live lease. Recovery keeps its
            // durable terminal record but cannot invent historical usage.
            case None => return Result.Ok(())
        }
        match (selected.settle(usage)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) =>
                lock.lock()
                try {
                    childBudgetLeases.remove(childId)
                    childUsage.remove(childId)
                } finally {
                    lock.unlock()
                }
                Result.Ok(())
        }
    }

    private func takeYield(subagentId: String): ProductYieldState {
        lock.lock()
        try {
            let state = findSubagentLocked(subagentId).getOrThrow()
            findYieldLocked(state.runId).getOrThrow()
        } finally {
            lock.unlock()
        }
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

    private func listenerSinksLocked(): Array<ProductSubagentEventSink> {
        let values = ArrayList<ProductSubagentEventSink>()
        for (listener in listeners) {
            values.add(listener.sink)
        }
        values.toArray()
    }

    private func pruneSubagentsLocked(): Unit {
        while (records.size > 256) {
            var removeIndex: Int64 = -1
            for (index in 0..records.size) {
                let status = records[index].status
                if (status != "running" && status != "blocked") {
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

    func executeProcessOperation(
        context: ToolInvocationContext,
        call: ToolCall,
        op: String
    ): Result<ToolResult> {
        let supervisor = match (processSupervisorValue()) {
            case Some(value) => value
            case None => return taskError<ToolResult>(
                "hub.process_supervisor_unavailable",
                "process supervisor is not attached"
            )
        }
        let broker = match (processBrokerValue()) {
            case Some(value) => value
            case None => return taskError<ToolResult>(
                "hub.process_broker_unavailable",
                "process broker is not attached"
            )
        }
        if (op == "start") {
            if (daemonBoolean(call, "persist", false) || daemonBoolean(call, "detached", false)) {
                if (supervisor.contains(daemonText(call, "name"))) {
                    return taskError<ToolResult>(
                        "hub.process_exists",
                        "process already exists in the local supervisor"
                    )
                }
                return broker.execute(call, op, context.sessionId.value)
            }
            return supervisor.execute(call, op, context.sessionId.value)
        }
        if (op == "ps") {
            let local = match (supervisor.execute(call, op, context.sessionId.value)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let remoteResult = match (broker.executeIfConfigured(
                call,
                op,
                context.sessionId.value
            )) {
                case Some(value) => value
                case None => return Result.Ok(local)
            }
            let remote = match (remoteResult) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            return mergeProcessLists(call.callId, local, remote)
        }
        let name = daemonText(call, "name")
        if (name != "" && supervisor.contains(name)) {
            return supervisor.execute(call, op, context.sessionId.value)
        }
        broker.execute(call, op, context.sessionId.value)
    }

    private func processSupervisorValue(): ?ProductProcessSupervisor {
        lock.lock()
        try {
            processSupervisor
        } finally {
            lock.unlock()
        }
    }

    private func processBrokerValue(): ?ProductProcessBroker {
        lock.lock()
        try {
            processBroker
        } finally {
            lock.unlock()
        }
    }

    private func takeHubMessages(
        context: ToolInvocationContext,
        from: String,
        peek: Bool
    ): Result<Array<ProductHubMessageSnapshot>> {
        lock.lock()
        try {
            let caller = hubIdentityLocked(context)
            let values = ArrayList<ProductHubMessageSnapshot>()
            let consumed = ArrayList<ProductHubMessageState>()
            for (state in hubMessages where !state.consumed && state.snapshot.to == caller.id &&
                state.rootSessionId.value == caller.rootSessionId.value && (from == "" || state.snapshot.from == from)) {
                values.add(state.snapshot)
                if (!peek) {
                    state.consumed = true
                    consumed.add(state)
                }
            }
            if (!peek && !values.isEmpty()) {
                match (persistRootLocked(caller.rootSessionId)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        for (state in consumed) { state.consumed = false }
                        rememberTaskPersistenceFailureLocked(caller.rootSessionId, error)
                        return Result.Err(error)
                }
            }
            Result.Ok(values.toArray())
        } finally {
            lock.unlock()
        }
    }

    private func waitForHubMessage(
        context: ToolInvocationContext,
        from: String,
        timeoutMillis: Int64
    ): Result<?ProductHubMessageSnapshot> {
        let started = nowMillis()
        while (true) {
            let values = match (takeHubMessages(context, from, false)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (!values.isEmpty()) {
                return Result.Ok(Some(values[0]))
            }
            if (timeoutMillis > 0 && nowMillis() - started >= timeoutMillis) {
                return Result.Ok(None)
            }
            sleep(Duration.millisecond * 10)
        }
        Result.Ok(None)
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

    private func jobListenerSinksLocked(): Array<ProductAsyncJobEventSink> {
        let values = ArrayList<ProductAsyncJobEventSink>()
        for (listener in jobListeners) {
            values.add(listener.sink)
        }
        values.toArray()
    }

    private func emitJobEvent(
        kind: String,
        snapshot: ProductAsyncJobSnapshot
    ): Unit {
        let sinks: Array<ProductAsyncJobEventSink>
        lock.lock()
        try {
            sinks = jobListenerSinksLocked()
        } finally {
            lock.unlock()
        }
        let event = ProductAsyncJobEvent(kind, snapshot)
        for (sink in sinks) {
            sink(event)
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

    private func jobSelectionByKeys(keys: Array<ProductAsyncJobKey>): ProductAsyncJobSelection {
        lock.lock()
        try {
            let values = ArrayList<ProductAsyncJobSnapshot>()
            var settledAndDelivered = false
            for (key in keys) {
                match (findJobLocked(key)) {
                    case Some(job) =>
                        values.add(job.snapshot())
                        if (job.status != "running" && job.settlementInjected) {
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

    private func finishBackgroundTask(
        context: ToolInvocationContext,
        call: ToolCall,
        key: ProductAsyncJobKey,
        outcome: Result<ProductTaskResult>
    ): Unit {
        let snapshot: ProductAsyncJobSnapshot
        var emitSettlement = false
        lock.lock()
        try {
            let job = findJobLocked(key).getOrThrow()
            if (job.status == "cancelled") {
                emitSettlement = false
                job.executing = false
                prepareJobSettlementLocked(job)
            } else {
                emitSettlement = true
                match (outcome) {
                    case Result.Ok(value) =>
                        job.result = Some(taskPersistBoundJobResult(productTaskResultValue(value)))
                        job.status = if (value.exitCode == 0) {
                            "completed"
                        } else if (value.snapshot.status == "cancelled") {
                            "cancelled"
                        } else if (value.snapshot.status == "blocked") {
                            "blocked"
                        } else {
                            "failed"
                        }
                        job.error = value.stderr
                    case Result.Err(error) =>
                        job.status = "failed"
                        job.error = error.message
                }
                job.updatedAt = nowMillis()
                job.executing = false
                prepareJobSettlementLocked(job)
            }
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    markJobPersistenceRecoveryLocked(job, error)
                    let _ = persistRootLocked(job.rootSessionId)
                    emitSettlement = false
            }
            snapshot = job.snapshot()
        } finally {
            lock.unlock()
        }
        deliverBackgroundSnapshot(
            context,
            call,
            key,
            snapshot,
            emitSettlement
        )
    }

    private func finishBackgroundBash(
        context: ToolInvocationContext,
        call: ToolCall,
        key: ProductAsyncJobKey,
        outcome: Result<ToolResult>
    ): Unit {
        let snapshot: ProductAsyncJobSnapshot
        var emitSettlement = false
        lock.lock()
        try {
            let job = findJobLocked(key).getOrThrow()
            if (job.status == "cancelled") {
                emitSettlement = false
                job.executing = false
                prepareJobSettlementLocked(job)
            } else {
                emitSettlement = true
                match (outcome) {
                    case Result.Ok(value) =>
                        job.result = Some(taskPersistBoundJobResult(value.output))
                        job.status = if (value.isError) {
                            "failed"
                        } else {
                            "completed"
                        }
                        job.error = if (value.isError) {
                            "bash job failed"
                        } else {
                            ""
                        }
                    case Result.Err(error) =>
                        job.status = "failed"
                        job.error = error.message
                }
                job.updatedAt = nowMillis()
                job.executing = false
                prepareJobSettlementLocked(job)
            }
            match (persistRootLocked(job.rootSessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    markJobPersistenceRecoveryLocked(job, error)
                    let _ = persistRootLocked(job.rootSessionId)
                    emitSettlement = false
            }
            snapshot = job.snapshot()
        } finally {
            lock.unlock()
        }
        deliverBackgroundSnapshot(
            context,
            call,
            key,
            snapshot,
            emitSettlement
        )
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

public class ProductTaskTool <: ToolExecutor {
    private let runtime: ProductTaskRuntime

    public init(runtime: ProductTaskRuntime) {
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.executeTask(context, call)
    }

    public func cancel(runId: RunId): Result<Unit> {
        runtime.cancel(runId)
    }

    public func afterResultPersisted(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        runtime.deliverHubMessagesAfterParentResult(
            context.sessionId, result.callId
        )
    }
}

public class ProductYieldTool <: ToolExecutor {
    private let runtime: ProductTaskRuntime

    public init(runtime: ProductTaskRuntime) {
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.submitYield(context, call)
    }
}

public class ProductHubTool <: ToolExecutor {
    private let runtime: ProductTaskRuntime

    public init(runtime: ProductTaskRuntime) {
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let op = match (productTaskText(call, "op", true)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let processName = daemonText(call, "name")
        if (op == "send" && processName != "") {
            if (daemonText(call, "to") != "") {
                return taskError<ToolResult>(
                    "hub.send_target_conflict",
                    "to and name are mutually exclusive for hub send"
                )
            }
            return runtime.executeProcessOperation(context, call, op)
        }
        if (op == "wait" && processName != "") {
            return runtime.executeProcessOperation(context, call, op)
        }
        if (op == "start" || op == "ps" || op == "logs" || op == "stop" || op == "restart" || op == "describe") {
            return runtime.executeProcessOperation(context, call, op)
        }
        if (op == "send") {
            let to = match (productTaskText(call, "to", true)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let message = match (productTaskText(
                call,
                "message",
                true
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let replyTo = match (productTaskText(
                call,
                "replyTo",
                false
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let timeout = match (jobTimeout(call)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            return runtime.sendHubMessage(
                context,
                call,
                to,
                message,
                replyTo,
                optionalBoolean(call, "await", false),
                timeout
            )
        }
        if (op == "inbox") {
            return runtime.hubInbox(
                context,
                call,
                optionalBoolean(call, "peek", false)
            )
        }
        if (op == "list") {
            return runtime.hubPeers(context, call)
        }
        let from = match (productTaskText(call, "from", false)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (op == "wait" && from != "") {
            let timeout = match (jobTimeout(call)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            return runtime.hubMessageWait(
                context,
                call,
                from,
                timeout
            )
        }
        let ids = match (jobIds(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let snapshots = match (op) {
            case "jobs" =>
                if (!ids.isEmpty()) {
                    return taskError<ToolResult>(
                        "hub.invalid_arguments",
                        "hub jobs does not accept ids"
                    )
                }
                runtime.jobsFor(context.sessionId)
            case "wait" =>
                let timeout = match (jobTimeout(call)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                runtime.waitForJobs(context.sessionId, ids, timeout)
            case "cancel" =>
                if (ids.isEmpty()) {
                    return taskError<ToolResult>(
                        "hub.ids_required",
                        "hub cancel requires one or more job ids"
                    )
                }
                runtime.cancelJobs(context.sessionId, ids)
            case _ => return taskError<ToolResult>(
                "hub.op_invalid",
                "unsupported hub operation: " + op
            )
        }
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("op", textValue(op)))
        fields.add(ValueField("jobs", asyncJobsValue(snapshots)))
        let warnings = runtime.recoveryWarningsFor(context)
        if (!warnings.isEmpty()) {
            fields.add(ValueField("recoveryWarnings", taskStringValues(warnings)))
        }
        Result.Ok(ToolResult(call.callId, objectValue(fields.toArray())))
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

func parseProductTaskBatch(call: ToolCall): Result<ProductTaskBatch> {
    let tasksValue = call.arguments.field("tasks")
    if (tasksValue.isNone()) {
        let context = match (productTaskText(call, "context", false)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        return match (parseProductTask(call)) {
            case Result.Ok(value) => Result.Ok(ProductTaskBatch(context, [value], false))
            case Result.Err(error) => Result.Err(error)
        }
    }
    for (field in call.arguments.fields) {
        if (field.name != "context" && field.name != "tasks") {
            return taskError<ProductTaskBatch>(
                "task.invalid_arguments",
                "batch task only accepts context and tasks"
            )
        }
    }
    let context = match (call.arguments.field("context")) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Text || value.text.trimAscii() == "") {
                return taskError<ProductTaskBatch>(
                    "task.context_required",
                    "batch task requires non-empty context"
                )
            }
            value.text
        case None => return taskError<ProductTaskBatch>(
            "task.context_required",
            "batch task requires non-empty context"
        )
    }
    let raw = tasksValue.getOrThrow()
    if (raw.unifiedKind != ValueKind.List || raw.items.isEmpty() || raw.items.size > 8) {
        return taskError<ProductTaskBatch>(
            "task.batch_size",
            "tasks must contain between 1 and 8 task items"
        )
    }
    let specs = ArrayList<ProductTaskSpec>()
    let names = ArrayList<String>()
    var index: Int64 = 0
    for (item in raw.items) {
        if (item.unifiedKind != ValueKind.Object) {
            return taskError<ProductTaskBatch>(
                "task.item_invalid",
                "every tasks item must be an object"
            )
        }
        let spec = match (parseProductTask(
            ToolCall(
                call.callId + "-" + index.toString(),
                "task",
                item
            )
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (spec.name != "") {
            if (containsTaskStringIgnoreAsciiCase(
                names.toArray(),
                spec.name
            )) {
                return taskError<ProductTaskBatch>(
                    "task.name_duplicate",
                    "task names must be unique within a batch"
                )
            }
            names.add(spec.name)
        }
        specs.add(spec)
        index += 1
    }
    Result.Ok(ProductTaskBatch(context, specs.toArray(), true))
}

func parseProductTask(call: ToolCall): Result<ProductTaskSpec> {
    for (field in call.arguments.fields) {
        if (field.name != "name" && field.name != "agent" && field.name != "task" && field.name != "effort" &&
            field.name != "context" && field.name != "outputSchema" && field.name != "schemaMode") {
            return taskError<ProductTaskSpec>(
                "task.invalid_arguments",
                "unknown task argument: " + field.name
            )
        }
    }
    let name = match (productTaskText(call, "name", false)) {
        case Result.Ok(value) => normalizeTaskName(value)
        case Result.Err(error) => return Result.Err(error)
    }
    let agent = match (productTaskText(call, "agent", false)) {
        case Result.Ok(value) =>
            if (value == "") {
                "task"
            } else {
                value
            }
        case Result.Err(error) => return Result.Err(error)
    }
    if (!validProductAgent(agent)) {
        return taskError<ProductTaskSpec>(
            "task.agent_unknown",
            "unknown bundled agent: " + agent
        )
    }
    let task = match (productTaskText(call, "task", true)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let effort = match (productTaskText(
        call,
        "effort",
        false
    )) {
        case Result.Ok(value) =>
            if (value == "") {
                "med"
            } else {
                value
            }
        case Result.Err(error) => return Result.Err(error)
    }
    if (effort != "lo" && effort != "med" && effort != "hi") {
        return taskError<ProductTaskSpec>(
            "task.effort_invalid",
            "effort must be lo, med, or hi"
        )
    }
    let schemaMode = match (productTaskText(
        call,
        "schemaMode",
        false
    )) {
        case Result.Ok(value) =>
            if (value == "") {
                "permissive"
            } else {
                value
            }
        case Result.Err(error) => return Result.Err(error)
    }
    if (schemaMode != "permissive" && schemaMode != "strict") {
        return taskError<ProductTaskSpec>(
            "task.schema_mode_invalid",
            "schemaMode must be permissive or strict"
        )
    }
    let outputSchema: ?AgentValue = match (call.arguments.field("outputSchema")) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Null) {
                None
            } else if (value.unifiedKind == ValueKind.Object || value.unifiedKind == ValueKind.Boolean || value.unifiedKind == ValueKind.Text) {
                Some(value)
            } else {
                return taskError<ProductTaskSpec>(
                    "task.output_schema_invalid",
                    "outputSchema must be an object, boolean, string, or null"
                )
            }
        case None => None
    }
    Result.Ok(
        ProductTaskSpec(
            name,
            agent,
            task,
            effort,
            outputSchema,
            schemaMode
        )
    )
}

func productTaskText(
    call: ToolCall,
    name: String,
    required: Bool
): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Text) {
                taskError<String>(
                    "task.invalid_arguments",
                    name + " must be a string"
                )
            } else if (required && value.text.trimAscii() == "") {
                taskError<String>(
                    "task.invalid_arguments",
                    name + " must not be empty"
                )
            } else {
                Result.Ok(value.text.trimAscii())
            }
        case None =>
            if (required) {
                taskError<String>(
                    "task.invalid_arguments",
                    name + " is required"
                )
            } else {
                Result.Ok("")
            }
    }
}

func normalizeTaskName(source: String): String {
    if (source == "") {
        return ""
    }
    var result = source.replace("\n", " ").replace("\r", " ").replace("\t", " ").trimAscii()
    while (result.contains("  ")) {
        result = result.replace("  ", " ")
    }
    if (result.size <= 80) {
        result
    } else {
        result[..79] + "…"
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

public func bundledProductAgents(): Array<ProductBundledAgentDefinition> {
    let values = ArrayList<ProductBundledAgentDefinition>()
    for (name in [
        "designer",
        "librarian",
        "reviewer",
        "scout",
        "sonic",
        "task"
    ]) {
        values.add(
            ProductBundledAgentDefinition(
                name,
                productAgentDescription(name),
                productAgentPrompt(name),
                spawns: if (name == "task") {
                    "*"
                } else {
                    ""
                },
                model: if (name == "task") {
                    "@task"
                } else if (name == "sonic") {
                    "@smol"
                } else {
                    ""
                },
                thinkingLevel: if (name == "sonic") {
                    "medium"
                } else {
                    ""
                }
            )
        )
    }
    values.toArray()
}

func validProductAgent(agent: String): Bool {
    agent == "task" || agent == "scout" || agent == "designer" || agent == "reviewer" || agent == "librarian" ||
        agent == "sonic"
}

func productAgentDescription(agent: String): String {
    match (agent) {
        case "scout" => "Fast codebase exploration and evidence gathering"
        case "designer" => "Architecture and implementation design"
        case "reviewer" => "Correctness and regression review"
        case "librarian" => "Documentation and source research"
        case "sonic" => "Focused low-latency execution"
        case _ => "General delegated implementation"
    }
}

func productAgentPrompt(agent: String): String {
    "You are the " + agent + " delegated agent. " + productAgentDescription(agent) +
        ". Complete only the assigned task. " +
        "Once the requested evidence is available, stop exploring and immediately use the yield tool for structured " +
        "output; do not continue reasoning or issue redundant tool calls. " +
        "If yield is not appropriate, end with a concise final report."
}

// Child runs have their own literal stable prefix. Reusing a parent's cache
// key after replacing its system prompt would associate different prefixes
// with one key. Shared context remains delimited, external turn data.
func productSubagentPrompt(agent: String, sharedContext: String): PromptBuild {
    let builder = PromptBuilder()
    builder.add(PromptSection(
        PromptSectionKind.Base,
        PromptTrust.System,
        PromptStability.Stable,
        "axyndra-subagent-" + agent,
        "1",
        productAgentPrompt(agent)
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
    agent: String,
    capabilities: CapabilitySet,
    sharedContext!: String = ""
): AgentRunRequest {
    let promptBuild = productSubagentPrompt(agent, sharedContext)
    AgentRunRequest(
        base.runId,
        base.sessionId,
        base.model,
        base.prompt,
        system: promptBuild.text,
        thinking: base.thinking,
        capabilities: capabilities,
        budget: ResourceBudget(
            maxInputTokens: base.budget.maxInputTokens,
            maxOutputTokens: min(8000, base.budget.maxOutputTokens),
            maxTotalInputTokens: base.budget.maxTotalInputTokens,
            maxTotalOutputTokens: base.budget.maxTotalOutputTokens,
            maxModelRequests: min(12, base.budget.maxModelRequests),
            maxTurns: min(12, base.budget.maxTurns),
            maxToolCalls: min(24, base.budget.maxToolCalls),
            maxWallMillis: if (base.budget.maxWallMillis == 0) {
                300000
            } else {
                min(300000, base.budget.maxWallMillis)
            },
            maxIdleMillis: min(90000, base.budget.maxIdleMillis),
            maxChildren: min(8, base.budget.maxChildren),
            maxDepth: min(4, base.budget.maxDepth),
            maxConcurrentChildren: min(4, base.budget.maxConcurrentChildren),
            maxContextMessages: base.budget.maxContextMessages,
            maxConcurrentTools: base.budget.maxConcurrentTools,
            maxCostMicros: base.budget.maxCostMicros,
            deadlineMillis: base.budget.deadlineMillis
        ),
        approvalModeOverride: None,
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
        toolContext: base.toolContext
    )
}

// A child can only lose authority. Role ceilings are product policy; the
// effective set is still intersected with both the parent's grant and the
// execution/sandbox ceiling by agent_runtime.
func productAgentCapabilityCeiling(agent: String): CapabilitySet {
    let values = ArrayList<Capability>()
    values.add(Capability(CapabilityKind.WorkspaceRead))
    values.add(Capability(CapabilityKind.PeerMessage))
    if (agent == "librarian") {
        values.add(Capability(CapabilityKind.NetworkAccess))
    }
    if (agent == "task" || agent == "sonic") {
        values.add(Capability(CapabilityKind.WorkspaceWrite))
        values.add(Capability(CapabilityKind.ProcessSpawn))
    }
    if (agent == "task") {
        values.add(Capability(CapabilityKind.NetworkAccess))
        values.add(Capability(CapabilityKind.ExtensionInvoke))
        values.add(Capability(CapabilityKind.Delegate))
    }
    CapabilitySet(values: values.toArray())
}

func taskThinking(effort: String): ThinkingLevel {
    match (effort) {
        case "lo" => ThinkingLevel.Low
        case "hi" => ThinkingLevel.High
        case _ => ThinkingLevel.Medium
    }
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
                    Int64.parse(field.number)
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

func yieldedOutput(state: ProductYieldState, lastText: String): AgentValue {
    match (state.terminal) {
        case Some(value) => value
        case None =>
            if (state.useLastTurn) {
                return textValue(lastText)
            }
            if (!state.sections.isEmpty()) {
                let fields = ArrayList<ValueField>()
                for (section in state.sections) {
                    for (label in section.labels) {
                        fields.add(ValueField(label, section.data))
                    }
                }
                return objectValue(fields.toArray())
            }
            let parsed = decodeAgentValue(lastText)
            match (parsed) {
                case Result.Ok(value) => value
                case Result.Err(_) => textValue(lastText)
            }
    }
}

func yieldLabels(value: ?AgentValue): Result<Array<String>> {
    match (value) {
        case None => Result.Ok([])
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) {
                if (field.text.trimAscii() == "") {
                    taskError<Array<String>>(
                        "yield.type_invalid",
                        "type must be a non-empty string"
                    )
                } else {
                    Result.Ok([field.text])
                }
            } else if (field.unifiedKind == ValueKind.List) {
                let labels = ArrayList<String>()
                for (item in field.items) {
                    if (item.unifiedKind != ValueKind.Text || item.text.trimAscii() == "") {
                        return taskError<Array<String>>(
                            "yield.type_invalid",
                            "type must be a string or non-empty string array"
                        )
                    }
                    labels.add(item.text)
                }
                if (labels.isEmpty()) {
                    taskError<Array<String>>(
                        "yield.type_invalid",
                        "type must be a string or non-empty string array"
                    )
                } else {
                    Result.Ok(labels.toArray())
                }
            } else {
                taskError<Array<String>>(
                    "yield.type_invalid",
                    "type must be a string or non-empty string array"
                )
            }
    }
}

func validateTaskSchema(
    schema: ?AgentValue,
    output: AgentValue
): TaskSchemaValidation {
    match (schema) {
        case None => TaskSchemaValidation(true)
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Boolean) {
                return if (value.boolean) {
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

func productTaskResultValue(result: ProductTaskResult): AgentValue {
    let snapshot = result.snapshot
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("index", integerValue(snapshot.index)))
    fields.add(ValueField("id", textValue(snapshot.id)))
    fields.add(ValueField("agent", textValue(snapshot.agent)))
    fields.add(
        ValueField(
            "agentSource",
            textValue(snapshot.agentSource)
        )
    )
    fields.add(ValueField("task", textValue(snapshot.task)))
    fields.add(ValueField("assignment", textValue(snapshot.assignment)))
    fields.add(ValueField("exitCode", integerValue(result.exitCode)))
    fields.add(
        ValueField(
            "output",
            textValue(if (result.output.unifiedKind == ValueKind.Text) {
                result.output.text
            } else {
                encodeAgentValue(result.output)
            })
        )
    )
    fields.add(ValueField("stderr", textValue(result.stderr)))
    fields.add(ValueField("truncated", boolValue(false)))
    fields.add(ValueField("tokens", integerValue(snapshot.tokens)))
    fields.add(ValueField("requests", integerValue(snapshot.requests)))
    fields.add(ValueField("sessionRef", textValue(snapshot.sessionRef)))
    fields.add(ValueField("runId", textValue(snapshot.runId.value)))
    fields.add(ValueField("status", textValue(snapshot.status)))
    if (result.schemaStatus != "unavailable") {
        fields.add(
            ValueField(
                "structuredOutput",
                objectValue(
                    [
                        ValueField("source", textValue("caller")),
                        ValueField("mode", textValue(result.schemaMode)),
                        ValueField("status", textValue(result.schemaStatus)),
                        ValueField("data", result.output),
                        ValueField("error", textValue(result.schemaError))
                    ]
                )
            )
        )
    }
    objectValue(fields.toArray())
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

func hubMessageValue(message: ProductHubMessageSnapshot): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("id", textValue(message.id)))
    fields.add(ValueField("from", textValue(message.from)))
    fields.add(ValueField("to", textValue(message.to)))
    fields.add(ValueField("message", textValue(message.message)))
    if (message.replyTo != "") {
        fields.add(
            ValueField(
                "replyTo",
                textValue(message.replyTo)
            )
        )
    }
    fields.add(
        ValueField(
            "createdAt",
            integerValue(message.createdAt)
        )
    )
    objectValue(fields.toArray())
}

func hubMessagesValue(messages: Array<ProductHubMessageSnapshot>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (message in messages) {
        values.add(hubMessageValue(message))
    }
    listValue(values.toArray())
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

func asyncJobsValue(jobs: Array<ProductAsyncJobSnapshot>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (job in jobs) {
        values.add(asyncJobValue(job))
    }
    listValue(values.toArray())
}

func taskStringValues(values: Array<String>): AgentValue {
    let encoded = ArrayList<AgentValue>()
    for (value in values) {
        encoded.add(textValue(value))
    }
    listValue(encoded.toArray())
}

func cancelBashOperation(
    runtime: ProductRuntime,
    operationId: String
): Unit {
    for (_ in 0..100) {
        match (runtime.abortBash(OperationId(operationId))) {
            case Result.Ok(_) => return
            case Result.Err(error) =>
                if (error.code != "process.operation_not_running") {
                    return
                }
        }
        sleep(Duration.millisecond * 10)
    }
}

func productAgentBlocks(agent: String): Bool {
    agent == "scout"
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

func containsTaskStringIgnoreAsciiCase(
    values: Array<String>,
    expected: String
): Bool {
    for (value in values where taskStringsEqualIgnoreAsciiCase(value, expected)) {
        return true
    }
    false
}

func taskStringsEqualIgnoreAsciiCase(
    left: String,
    right: String
): Bool {
    let leftBytes = unsafe { left.rawData() }
    let rightBytes = unsafe { right.rawData() }
    if (leftBytes.size != rightBytes.size) {
        return false
    }
    for (index in 0..leftBytes.size) {
        if (taskAsciiLower(leftBytes[index]) != taskAsciiLower(rightBytes[index])) {
            return false
        }
    }
    true
}

func taskAsciiLower(value: Byte): Byte {
    if (value >= b'A' && value <= b'Z') {
        value + b' '
    } else {
        value
    }
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

func jobIds(call: ToolCall): Result<Array<String>> {
    let value = match (call.arguments.field("ids")) {
        case Some(value) => value
        case None => return Result.Ok([])
    }
    if (value.unifiedKind != ValueKind.List) {
        return taskError<Array<String>>(
            "hub.ids_invalid",
            "hub ids must be an array of strings"
        )
    }
    let ids = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != ValueKind.Text || item.text.trimAscii() == "") {
            return taskError<Array<String>>(
                "hub.ids_invalid",
                "hub ids must contain non-empty strings"
            )
        }
        if (!containsTaskString(ids.toArray(), item.text)) {
            ids.add(item.text)
        }
    }
    Result.Ok(ids.toArray())
}

func jobTimeout(call: ToolCall): Result<Int64> {
    let value = match (call.arguments.field("timeoutMs")) {
        case Some(value) => value
        case None => return Result.Ok(30000)
    }
    if (value.unifiedKind != ValueKind.Number) {
        return taskError<Int64>(
            "hub.timeout_invalid",
            "hub timeoutMs must be a non-negative integer"
        )
    }
    let timeout = try {
        Int64.parse(value.number)
    } catch (_: Exception) {
        return taskError<Int64>(
            "hub.timeout_invalid",
            "hub timeoutMs must be a non-negative integer"
        )
    }
    if (timeout < 0 || timeout > 300000) {
        return taskError<Int64>(
            "hub.timeout_invalid",
            "hub timeoutMs must be between 0 and 300000"
        )
    }
    Result.Ok(timeout)
}

func yieldArgumentError(
    call: ToolCall,
    message: String
): Result<ToolResult> {
    Result.Ok(
        ToolResult(
            call.callId,
            objectValue([ValueField("error", textValue(message))]),
            isError: true
        )
    )
}

func emitToSinks(
    sinks: Array<ProductSubagentEventSink>,
    event: ProductSubagentEvent
): Unit {
    for (sink in sinks) {
        sink(event)
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

func mergeProcessLists(
    callId: String,
    local: ToolResult,
    remote: ToolResult
): Result<ToolResult> {
    let values = ArrayList<AgentValue>()
    for (result in [local, remote]) {
        let daemons = match (result.output.field("daemons")) {
            case Some(value) => value
            case None => return taskError<ToolResult>(
                "hub.process_list_invalid",
                "process supervisor returned no daemon list"
            )
        }
        if (daemons.unifiedKind != ValueKind.List) {
            return taskError<ToolResult>(
                "hub.process_list_invalid",
                "process supervisor returned an invalid daemon list"
            )
        }
        for (daemon in daemons.items) { values.add(daemon) }
    }
    Result.Ok(ToolResult(
        callId,
        objectValue([
            ValueField("op", textValue("ps")),
            ValueField("daemons", listValue(values.toArray()))
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
