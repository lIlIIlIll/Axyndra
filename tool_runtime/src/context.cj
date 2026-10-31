package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.deriving.*
import std.sync.*
import yjson_support.*
import yjson.*

// A deliberately filtered, immutable view.  It never reads the host
// environment; composition roots must explicitly provide every visible value.
public class ToolEnvironmentEntry {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        let normalized = name.trimAscii()
        if (!validToolEnvironmentName(normalized) ||
            normalized.contains("\u{0000}") || value.contains("\u{0000}")) {
            throw IllegalArgumentException("tool environment entries must be valid explicit name/value pairs")
        }
        this.name = normalized
        this.value = value
    }
}

public class ToolEnvironmentView {
    private let values: Array<ToolEnvironmentEntry>

    public init(entries!: Array<ToolEnvironmentEntry> = []) {
        let snapshot = ArrayList<ToolEnvironmentEntry>()
        for (entry in entries) {
            var replaced = false
            for (index in 0..snapshot.size) {
                if (snapshot[index].name == entry.name) {
                    snapshot[index] = ToolEnvironmentEntry(entry.name, entry.value)
                    replaced = true
                    break
                }
            }
            if (!replaced) {
                snapshot.add(ToolEnvironmentEntry(entry.name, entry.value))
            }
        }
        values = snapshot.toArray()
    }

    public func value(name: String): ?String {
        for (entry in values where entry.name == name) {
            return Some(entry.value)
        }
        None
    }

    public func names(): Array<String> {
        let result = ArrayList<String>()
        for (entry in values) { result.add(entry.name) }
        result.toArray()
    }

    public func entries(): Array<ToolEnvironmentEntry> {
        let result = ArrayList<ToolEnvironmentEntry>()
        for (entry in values) {
            result.add(ToolEnvironmentEntry(entry.name, entry.value))
        }
        result.toArray()
    }
}

@Derive[Equatable]
public enum ToolServiceKind {
    Workspace | Process | Conversation | Artifact | Memory | Task | Extension | Custom
}

// Service descriptors advertise typed dependencies available to an executor.
// They do not grant capabilities and are never consulted by permission policy.
public class ToolServiceDescriptor {
    public let kind: ToolServiceKind
    public let name: String
    public let version: String

    public init(
        kind: ToolServiceKind,
        name: String,
        version!: String = ""
    ) {
        let normalized = name.trimAscii()
        if (normalized == "" || normalized.contains("\u{0000}") ||
            version.contains("\u{0000}")) {
            throw IllegalArgumentException("tool service name must not be empty")
        }
        this.kind = kind
        this.name = normalized
        this.version = version.trimAscii()
    }
}

func validToolEnvironmentName(value: String): Bool {
    if (value == "") { return false }
    let bytes = value.toArray()
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let letter = (byte >= b'a' && byte <= b'z') ||
            (byte >= b'A' && byte <= b'Z')
        if (!(letter || byte == b'_' ||
            (index > 0 && byte >= b'0' && byte <= b'9'))) {
            return false
        }
    }
    true
}

public class ToolServiceView {
    private let values: Array<ToolServiceDescriptor>

    public init(descriptors!: Array<ToolServiceDescriptor> = []) {
        let snapshot = ArrayList<ToolServiceDescriptor>()
        for (descriptor in descriptors) {
            var replaced = false
            for (index in 0..snapshot.size) {
                if (snapshot[index].kind == descriptor.kind &&
                    snapshot[index].name == descriptor.name) {
                    snapshot[index] = ToolServiceDescriptor(
                        descriptor.kind,
                        descriptor.name,
                        version: descriptor.version
                    )
                    replaced = true
                    break
                }
            }
            if (!replaced) {
                snapshot.add(ToolServiceDescriptor(
                    descriptor.kind,
                    descriptor.name,
                    version: descriptor.version
                ))
            }
        }
        values = snapshot.toArray()
    }

    public func contains(kind: ToolServiceKind, name!: String = ""): Bool {
        for (descriptor in values where descriptor.kind == kind &&
            (name == "" || descriptor.name == name)) {
            return true
        }
        false
    }

    public func descriptors(): Array<ToolServiceDescriptor> {
        let result = ArrayList<ToolServiceDescriptor>()
        for (descriptor in values) {
            result.add(ToolServiceDescriptor(
                descriptor.kind,
                descriptor.name,
                version: descriptor.version
            ))
        }
        result.toArray()
    }
}

// Durable request-side context.  Cancellation is intentionally absent: Core
// binds the live token owned by the current run when it creates the invocation
// context.
public class ToolContextDescriptor {
    public let workspaceRoot: String
    public let cwd: String
    public let environment: ToolEnvironmentView
    public let services: ToolServiceView
    // Frozen request configuration, not execution authority. Permissions still
    // evaluate the invocation capabilities against its one normalized plan.
    private let frozenExecutionSettings180: AgentValue
    public prop executionSettings180: AgentValue { get() {
        if (frozenExecutionSettings180.unifiedKind == ValueKind.Null) { frozenExecutionSettings180 }
        else { frozenExecutionSettings180.deepCopy() }
    } }
    public let modelFaultCounters180: ?ModelStreamFaultCounters180
    public func measureExecutionSettings180(meter: ToolSnapshotMeasure159): Unit {
        meter.addValue159(frozenExecutionSettings180)
        if (modelFaultCounters180.isSome()) { meter.addSlots159(32) }
    }
    public init(base: ToolContextDescriptor) {
        workspaceRoot = base.workspaceRoot; cwd = base.cwd
        environment = base.environment; services = base.services
        frozenExecutionSettings180 = base.frozenExecutionSettings180
        modelFaultCounters180 = base.modelFaultCounters180
    }


    public init(
        workspaceRoot!: String = "",
        cwd!: String = "",
        environment!: ToolEnvironmentView = ToolEnvironmentView(),
        services!: ToolServiceView = ToolServiceView(),
        executionSettings180!: AgentValue = nullValue(),
        modelFaultCounters180!: ?ModelStreamFaultCounters180 = None<ModelStreamFaultCounters180>
    ) {
        if (workspaceRoot.contains("\u{0000}") || cwd.contains("\u{0000}")) {
            throw IllegalArgumentException("tool context paths must not contain NUL")
        }
        this.workspaceRoot = workspaceRoot
        this.cwd = cwd
        this.environment = ToolEnvironmentView(entries: environment.entries())
        this.services = ToolServiceView(descriptors: services.descriptors())
        if (executionSettings180.unifiedKind != ValueKind.Null && executionSettings180.unifiedKind != ValueKind.Object) {
            throw IllegalArgumentException("execution settings must be an object or absent")
        }
        this.frozenExecutionSettings180 = if (executionSettings180.unifiedKind == ValueKind.Null) { executionSettings180 } else { executionSettings180.deepCopy() }
        this.modelFaultCounters180 = modelFaultCounters180
    }
    // The base has already frozen its immutable environment and service views.
    // Adding request configuration must not duplicate those paid snapshots.
    public init(base: ToolContextDescriptor, executionSettings180: AgentValue,
        modelFaultCounters180!: ?ModelStreamFaultCounters180 = None<ModelStreamFaultCounters180>) {
        if (executionSettings180.unifiedKind != ValueKind.Object && executionSettings180.unifiedKind != ValueKind.Null) {
            throw IllegalArgumentException("execution settings must be an object or absent")
        }
        workspaceRoot = base.workspaceRoot; cwd = base.cwd; environment = base.environment; services = base.services
        this.frozenExecutionSettings180 = if (executionSettings180.unifiedKind == ValueKind.Null) { executionSettings180 } else { executionSettings180.deepCopy() }
        this.modelFaultCounters180 = modelFaultCounters180
    }
}

private type InvocationValue_approvalModeOverride159 = ?ApprovalMode
private type InvocationValue_budgetModeFn159 = ?() -> BudgetMode
private type InvocationValue_hostDocumentCommitParticipant159 = ?PluginDocumentCommitParticipant

public class ToolInvocationContext {
    private var ownedInvocationData180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var invocationData_runId159: Option<RunId> = None<RunId>
    public prop runId: RunId {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_runId159() } else { parent.runId }
                    case None => invocationData_runId159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_sessionId159: Option<SessionId> = None<SessionId>
    public prop sessionId: SessionId {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_sessionId159() } else { parent.sessionId }
                    case None => invocationData_sessionId159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_epoch159: Option<Int64> = None<Int64>
    public prop epoch: Int64 {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_epoch159() } else { parent.epoch }
                    case None => invocationData_epoch159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_capabilities159: Option<CapabilitySet> = None<CapabilitySet>
    public prop capabilities: CapabilitySet {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_capabilities159() } else { parent.capabilities }
                    case None => invocationData_capabilities159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_workspaceRoot159: Option<String> = None<String>
    public prop workspaceRoot: String {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_workspaceRoot159() } else { parent.workspaceRoot }
                    case None => invocationData_workspaceRoot159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_cwd159: Option<String> = None<String>
    public prop cwd: String {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_cwd159() } else { parent.cwd }
                    case None => invocationData_cwd159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_environment159: Option<ToolEnvironmentView> = None<ToolEnvironmentView>
    public prop environment: ToolEnvironmentView {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_environment159() } else { parent.environment }
                    case None => invocationData_environment159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_cancellation159: Option<CancellationToken> = None<CancellationToken>
    public prop cancellation: CancellationToken {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_cancellation159() } else { parent.cancellation }
                    case None => invocationData_cancellation159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_services159: Option<ToolServiceView> = None<ToolServiceView>
    public prop services: ToolServiceView {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_services159() } else { parent.services }
                    case None => invocationData_services159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_executionSettings180: Option<AgentValue> = None<AgentValue>
    public prop executionSettings180: AgentValue {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_executionSettings180() } else { parent.executionSettings180 }
                    case None => let value = invocationData_executionSettings180.getOrThrow()
                        if (value.unifiedKind == ValueKind.Null) { value } else { fundSettingsCopy180(value); value.deepCopy() }
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var settingsCopyInvoice180: Int64 = 131072
    private func fundSettingsCopy180(value: AgentValue): Unit {
        if (value.unifiedKind == ValueKind.Null) { return }
        match (ownedInvocationData180) {
            case Some(paid) =>
                let meter = ToolSnapshotMeasure159(paid, priorInvoice: settingsCopyInvoice180)
                meter.addValue159(value); meter.addSlots159(32); meter.fund159()
                settingsCopyInvoice180 = meter.retainedInvoice159()
            case None => match (ownedToolSnapshot159) {
                case Some(owned) => owned.reserveInvocationSettingsCopy180(value)
                case None => match (deferredInvocationPayment159) {
                    case Some(owned) => owned.reserveInvocationSettingsCopy180(value); case None => () }
            }
        }
    }
    public func modelSettingsDescriptor180(): ToolContextDescriptor {
        beginInvocationAction159()
        try {
            let settings = executionSettings180
            // The getter paid its copy. This second immutable descriptor copy
            // is prepaid on the same actual view before construction.
            toolSnapshotLock159.lock()
            try { fundSettingsCopy180(settings) } finally { toolSnapshotLock159.unlock() }
            ToolContextDescriptor(executionSettings180: settings, modelFaultCounters180: modelFaultCounters180)
        } finally { endInvocationAction159() }
    }

    private var invocationData_modelFaultCounters180: Option<Option<ModelStreamFaultCounters180>> = None<Option<ModelStreamFaultCounters180>>
    public prop modelFaultCounters180: ?ModelStreamFaultCounters180 {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_modelFaultCounters180() } else { parent.modelFaultCounters180 }
                    case None => invocationData_modelFaultCounters180.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }

    private var invocationData_approvalModeOverride159: Option<InvocationValue_approvalModeOverride159> = None<InvocationValue_approvalModeOverride159>
    public prop approvalModeOverride: ?ApprovalMode {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_approvalModeOverride159() } else { parent.approvalModeOverride }
                    case None => invocationData_approvalModeOverride159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_outputSink159: Option<ToolOutputSink> = None<ToolOutputSink>
    public prop outputSink: ToolOutputSink {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_outputSink159() } else { parent.outputSink }
                    case None => invocationData_outputSink159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_budget159: Option<ExecutionBudget> = None<ExecutionBudget>
    public prop budget: ExecutionBudget {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_budget159() } else { parent.budget }
                    case None => invocationData_budget159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    // Live view of the owning run's BudgetMode. Captured as a closure so a
    // tool that reads it late (for example a child spawn admission check)
    // observes the run's current mode, not the mode at context creation.
    private var invocationData_budgetModeFn159: Option<InvocationValue_budgetModeFn159> = None<InvocationValue_budgetModeFn159>
    public prop budgetModeFn: ?() -> BudgetMode {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_budgetModeFn159() } else { parent.budgetModeFn }
                    case None => invocationData_budgetModeFn159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_contextProjection159: Option<InvocationContextProjection> = None<InvocationContextProjection>
    public prop contextProjection: InvocationContextProjection {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_contextProjection159() } else { parent.contextProjection }
                    case None => invocationData_contextProjection159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private let toolSnapshotLock159 = Mutex()
    private var rawToolSnapshot159: ?ToolSetSnapshot
    private var ownedToolSnapshot159: ?SharedToolSetSnapshot159
    private var toolSnapshotReturned159 = false
    private var invocationParent159: ?ToolInvocationContext = None<ToolInvocationContext>
    private var catalogInvocationRoot204: ?ToolInvocationContext = None<ToolInvocationContext>
    private var invocationView159 = false
    private var invocationRetained159: Bool = false
    private var invocationRevoked159 = false
    private var invocationActionFrames159: Int64 = 0
    private var invocationRetirementClaimed159 = false
    private var retainedInvocationChildren159: Int64 = 0
    private var deferredInvocationPayment159: ?SharedToolSetSnapshot159 = None<SharedToolSetSnapshot159>
    // Compatibility exports explicitly keep historical aliases paid. Internal
    // producers forward independent shares through the closed methods below.
    public prop toolSetSnapshot: ?ToolSetSnapshot {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (ownedToolSnapshot159) {
                    case Some(value) => Some(value.exportHistoricalSnapshot159())
                    case None => rawToolSnapshot159
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    public prop legacyToolSetSnapshot159: ?ToolSetSnapshot {
        get() {
            toolSnapshotLock159.lock()
            try { requireToolSnapshotFrame159(); rawToolSnapshot159 }
            finally { toolSnapshotLock159.unlock() }
        }
    }
    private var invocationData_trustedControl159: Option<Bool> = None<Bool>
    public prop trustedControl: Bool {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_trustedControl159() } else { parent.trustedControl }
                    case None => invocationData_trustedControl159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    // A live actual-user participant, never decoded from Tool arguments. New
    // derived/read contexts and snapshot views intentionally do not inherit it.
    private var invocationData_hostDocumentCommitParticipant159: Option<InvocationValue_hostDocumentCommitParticipant159> = None<InvocationValue_hostDocumentCommitParticipant159>
    public prop hostDocumentCommitParticipant: ?PluginDocumentCommitParticipant {
        get() {
            toolSnapshotLock159.lock()
            try {
                requireToolSnapshotFrame159()
                match (invocationParent159) {
                    case Some(parent) => if (invocationRetained159) { parent.retainedData_hostDocumentCommitParticipant159() } else { parent.hostDocumentCommitParticipant }
                    case None => invocationData_hostDocumentCommitParticipant159.getOrThrow()
                }
            } finally { toolSnapshotLock159.unlock() }
        }
    }
    private let sequenceLock = Mutex()
    private var sequenceOwner: ?ToolInvocationContext
    private let executionControlLock = Mutex()
    private var sequence: Int64
    private var auditSequence: Int64 = 0
    private var budgetChargeHandler: ?(BudgetCharge) -> Result<ExecutionUsage> = None
    private var ownedTaskHandler: ?(String, Future<Unit>) -> Result<Unit> = None
    private var nestedToolScheduler: ?(OperationId, () -> Result<Unit>) -> Result<Unit> = None
    private var derivedToolFrameHandler: ?(OperationId, OperationId, String, Bool) -> Result<Unit> = None
    private var paidExecutionFailureSink173: ?PaidExecutionFailureSink173 = None<PaidExecutionFailureSink173>
    public init(
        runId: RunId,
        sessionId: SessionId,
        capabilities: CapabilitySet,
        sequence!: Int64 = 0,
        epoch!: Int64 = 0,
        toolContext!: ToolContextDescriptor = ToolContextDescriptor(),
        cancellation!: CancellationToken = CancellationSource().token,
        approvalModeOverride!: ?ApprovalMode = None,
        outputSink!: ToolOutputSink = NoopToolOutputSink(),
        budget!: ExecutionBudget = ExecutionBudget(),
        budgetModeFn!: ?() -> BudgetMode = None,
        contextProjection!: InvocationContextProjection = InvocationContextProjection(),
        toolSetSnapshot!: ?ToolSetSnapshot = None,
        trustedControl!: Bool = false,
        hostDocumentCommitParticipant!: ?PluginDocumentCommitParticipant = None,
        ownedToolSetSnapshot159!: ?SharedToolSetSnapshot159 = None,
        ownedInvocationData180!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    ) {
        this.ownedInvocationData180 = ownedInvocationData180
        this.invocationData_runId159 = Some(runId)
        this.invocationData_sessionId159 = Some(sessionId)
        if (epoch < 0) { throw IllegalArgumentException("tool invocation epoch must not be negative") }
        this.invocationData_capabilities159 = Some(capabilities)
        this.invocationData_epoch159 = Some(epoch)
        this.invocationData_workspaceRoot159 = Some(toolContext.workspaceRoot)
        this.invocationData_cwd159 = Some(toolContext.cwd)
        this.invocationData_environment159 = Some(ToolEnvironmentView(entries: toolContext.environment.entries()))
        this.invocationData_cancellation159 = Some(cancellation)
        this.invocationData_services159 = Some(ToolServiceView(descriptors: toolContext.services.descriptors()))
        this.invocationData_executionSettings180 = Some(toolContext.executionSettings180)
        this.invocationData_modelFaultCounters180 = Some(toolContext.modelFaultCounters180)
        this.sequence = sequence
        this.sequenceOwner = None
        this.invocationData_approvalModeOverride159 = Some(approvalModeOverride)
        this.invocationData_outputSink159 = Some(outputSink)
        this.invocationData_budget159 = Some(budget)
        this.invocationData_budgetModeFn159 = Some(budgetModeFn)
        this.invocationData_contextProjection159 = Some(contextProjection)
        if (toolSetSnapshot.isSome() && ownedToolSetSnapshot159.isSome()) {
            throw IllegalArgumentException("tool context cannot replace an owned frozen snapshot with a raw alias")
        }
        this.rawToolSnapshot159 = toolSetSnapshot
        this.ownedToolSnapshot159 = ownedToolSetSnapshot159
        this.invocationData_trustedControl159 = Some(trustedControl)
        this.invocationData_hostDocumentCommitParticipant159 = Some(hostDocumentCommitParticipant)
    }

    // Revocation is not a consumer ACK. A saved Context shell has no private
    // graph after this scope is revoked; exported raw graphs stay Held in the
    // original Shared state, and explicitly forked shares remain independent.
    public func requireLiveInvocationView159(): Unit {
        toolSnapshotLock159.lock()
        try { requireToolSnapshotFrame159() } finally { toolSnapshotLock159.unlock() }
    }
    // An actual asynchronous/retained consumer explicitly takes its own
    // prepaid Context view. It must return that view only after its Future,
    // callbacks and captured fields have really returned/cleared. Ordinary
    // function return neither revokes nor refunds this independently held view.
    public func retainInvocationContext159(): ToolInvocationContext {
        beginInvocationAction159()
        try { retainInvocationContext159Action159() } finally { endInvocationAction159() }
    }

    private func retainInvocationContext159Action159(): ToolInvocationContext {
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            match (ownedToolSnapshot159) {
                case Some(owned) =>
                    let stable = match (invocationParent159) {
                        case Some(parent) => parent.stableInvocationOwner159()
                        case None => this }
                    let share = owned.forkInvocationView159()
                    // A real independently paid child, registered before its
                    // carrier is allocated. Parent retirement invalidates the
                    // parent's public view but keeps this exact data debt.
                    if (refEq(stable, this)) {
                        if (retainedInvocationChildren159 == Int64.Max) {
                            share.close159(); throw IllegalStateException("invocation child count overflow") }
                        retainedInvocationChildren159++
                    } else {
                        try { stable.addRetainedInvocationChild159() }
                        catch (error: Exception) { share.close159(); throw error }
                    }
                    try { ToolInvocationContext(stable, Some(share), None<LogicalJsonOwnerReservation>, retainedData159: true) }
                    catch (error: Exception) {
                        // The failed constructor has physically returned. The
                        // parent is still live under this call's actual loan.
                        if (refEq(stable, this)) { retainedInvocationChildren159-- }
                        else {
                            closeInvocationPayments180(stable.returnRetainedInvocationChild159())
                        }
                        share.close159(); throw error
                    }
                case None =>
                    let original = match (ownedInvocationData180) {
                        case Some(value) => value
                        case None => throw IllegalStateException("escaping Context has no prepaid DATA owner")
                    }
                    let stable = match (invocationParent159) {
                        case Some(parent) => parent.stableInvocationOwner159(); case None => this }
                    let child = original.deriveRetainedLease()
                    try { child.ensureRetainedPeak(16384) }
                    catch (error: Exception) { child.close(); throw error }
                    if (refEq(stable, this)) {
                        if (retainedInvocationChildren159 == Int64.Max) { child.close(); throw IllegalStateException("invocation child count overflow") }
                        retainedInvocationChildren159++
                    } else {
                        try { stable.addRetainedInvocationChild159() }
                        catch (error: Exception) { child.close(); throw error }
                    }
                    try { ToolInvocationContext(stable, None<SharedToolSetSnapshot159>, Some(child), retainedData159: true) }
                    catch (error: Exception) {
                        if (refEq(stable, this)) { retainedInvocationChildren159-- }
                        else { closeInvocationPayments180(stable.returnRetainedInvocationChild159()) }
                        child.close(); throw error
                    }

            }
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_runId159(): RunId {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_runId159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_sessionId159(): SessionId {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_sessionId159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_epoch159(): Int64 {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_epoch159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_capabilities159(): CapabilitySet {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_capabilities159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_workspaceRoot159(): String {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_workspaceRoot159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_cwd159(): String {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_cwd159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_environment159(): ToolEnvironmentView {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_environment159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_cancellation159(): CancellationToken {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_cancellation159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_services159(): ToolServiceView {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_services159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_executionSettings180(): AgentValue {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            let value = invocationData_executionSettings180.getOrThrow()
            if (value.unifiedKind == ValueKind.Null) { value } else { fundSettingsCopy180(value); value.deepCopy() }
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_modelFaultCounters180(): ?ModelStreamFaultCounters180 {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_modelFaultCounters180.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }

    private func retainedData_approvalModeOverride159(): InvocationValue_approvalModeOverride159 {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_approvalModeOverride159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_outputSink159(): ToolOutputSink {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_outputSink159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_budget159(): ExecutionBudget {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_budget159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_budgetModeFn159(): InvocationValue_budgetModeFn159 {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_budgetModeFn159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_contextProjection159(): InvocationContextProjection {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_contextProjection159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_trustedControl159(): Bool {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_trustedControl159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func retainedData_hostDocumentCommitParticipant159(): InvocationValue_hostDocumentCommitParticipant159 {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("no retained invocation data owner") }
            invocationData_hostDocumentCommitParticipant159.getOrThrow()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func addRetainedInvocationChild159(): Unit {
        toolSnapshotLock159.lock()
        try {
            if (toolSnapshotReturned159 && retainedInvocationChildren159 <= 0) {
                throw IllegalStateException("invocation data owner has returned") }
            if (retainedInvocationChildren159 == Int64.Max) { throw IllegalStateException("invocation child count overflow") }
            retainedInvocationChildren159++
        } finally { toolSnapshotLock159.unlock() }
    }
    private func returnRetainedInvocationChild159(): (?SharedToolSetSnapshot159, ?LogicalJsonOwnerReservation) {
        toolSnapshotLock159.lock()
        try {
            if (retainedInvocationChildren159 <= 0) { throw IllegalStateException("invocation child was not retained") }
            retainedInvocationChildren159--
            if (!toolSnapshotReturned159 || retainedInvocationChildren159 != 0) {
                return (None<SharedToolSetSnapshot159>, None<LogicalJsonOwnerReservation>) }
            clearPrivateInvocationData159()
            let snapshot = deferredInvocationPayment159; deferredInvocationPayment159 = None<SharedToolSetSnapshot159>
            let metadata = ownedInvocationData180; ownedInvocationData180 = None<LogicalJsonOwnerReservation>
            (snapshot, metadata)
        } finally { toolSnapshotLock159.unlock() }
    }
    private func closeInvocationPayments180(values: (?SharedToolSetSnapshot159, ?LogicalJsonOwnerReservation)): Unit {
        match (values[0]) { case Some(value) => value.close159(); case None => () }
        match (values[1]) { case Some(value) => value.close(); case None => () }
    }

    // Package-private actual-instance DATA identity. This is neither a Run id
    // nor a caller-supplied permission. The normal Context and its own paid
    // derived/view metadata retain this bounded pointer; no Scope is exported.
    func sameInvocationOwner204(other: ToolInvocationContext): Bool {
        beginInvocationAction159()
        try {
            other.beginInvocationAction159()
            try { refEq(catalogRootFrame204(), other.catalogRootFrame204()) }
            finally { other.endInvocationAction159() }
        } finally { endInvocationAction159() }
    }
    private func catalogRootFrame204(): ToolInvocationContext {
        toolSnapshotLock159.lock()
        try { match (catalogInvocationRoot204) { case Some(value) => value; case None => this } }
        finally { toolSnapshotLock159.unlock() }
    }

    func hasReturnedCatalogContextFrame204(): Bool {
        toolSnapshotLock159.lock()
        try { toolSnapshotReturned159 && invocationActionFrames159 == 0 } finally { toolSnapshotLock159.unlock() }
    }

    private func stableInvocationOwner159(): ToolInvocationContext {
        toolSnapshotLock159.lock()
        try {
            // Internal metadata ownership, never a public liveness or Source
            // check. A retained child may still own a revoked parent's data.
            if (toolSnapshotReturned159 && retainedInvocationChildren159 <= 0) {
                throw IllegalStateException("invocation data owner has returned") }
            match (invocationParent159) {
                case Some(parent) => parent.stableInvocationOwner159()
                case None => this }
        } finally { toolSnapshotLock159.unlock() }
    }
    func beginInvocationView159(): ToolInvocationContext {
        // Ordinary callback views also pin the private metadata owner. A
        // concurrent normal-owner retirement must not clear an already
        // entered callback's handler/sequence/carrier before that call ends.
        // Both paths share the same paid child registration; the wrapper,
        // rather than its callee, owns this particular scope's revocation.
        if (!hasOwnedToolSetSnapshot159() && !hasOwnedInvocationData180()) { return this }
        retainInvocationContext159Action159()
    }
    private init(parent: ToolInvocationContext, share: ?SharedToolSetSnapshot159, metadata: ?LogicalJsonOwnerReservation,
        retainedData159!: Bool = false) {
        invocationParent159 = Some(parent); invocationView159 = true
        catalogInvocationRoot204 = Some(parent.catalogRootFrame204())
        invocationRetained159 = retainedData159
        rawToolSnapshot159 = None<ToolSetSnapshot>; ownedToolSnapshot159 = share; ownedInvocationData180 = metadata
        sequence = 0; sequenceOwner = Some(parent)
        // No descriptor/environment/projection copy and no new closure here.
        // The parent fields are visible only through the live-view properties.
        parent.executionControlLock.lock()
        try {
            budgetChargeHandler = parent.budgetChargeHandler
            ownedTaskHandler = parent.ownedTaskHandler
            nestedToolScheduler = parent.nestedToolScheduler
            derivedToolFrameHandler = parent.derivedToolFrameHandler
            paidExecutionFailureSink173 = parent.paidExecutionFailureSink173
        } finally { parent.executionControlLock.unlock() }
    }
    func endInvocationView159(): Unit {
        if (invocationView159) { requestInvocationRetirement159() }
    }
    private func beginInvocationAction159(): Unit {
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            if (invocationActionFrames159 == Int64.Max) { throw IllegalStateException("invocation frame count overflow") }
            invocationActionFrames159++
        } finally { toolSnapshotLock159.unlock() }
    }
    private func endInvocationAction159(): Unit {
        let retire = finishInvocationActionFrame159()
        if (retire) { finishInvocationRetirement159() }
    }
    private func finishInvocationActionFrame159(): Bool {
        toolSnapshotLock159.lock()
        try {
            if (invocationActionFrames159 <= 0) { throw IllegalStateException("invocation action was not entered") }
            invocationActionFrames159--
            claimInvocationRetirement159()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func requestInvocationRetirement159(): Unit {
        let retire = revokeInvocationFrame159()
        if (retire) { finishInvocationRetirement159() }
    }
    private func revokeInvocationFrame159(): Bool {
        toolSnapshotLock159.lock()
        try {
            // New public getters/actions fail immediately. Already entered
            // action helpers retain the exact paid data/handler slots until
            // their actual stack frames return, even on another real thread.
            invocationRevoked159 = true
            claimInvocationRetirement159()
        } finally { toolSnapshotLock159.unlock() }
    }
    private func claimInvocationRetirement159(): Bool {
        if (!invocationRevoked159 || invocationActionFrames159 != 0 || invocationRetirementClaimed159) { return false }
        invocationRetirementClaimed159 = true
        true
    }
    private func finishInvocationRetirement159(): Unit {
        if (invocationView159) { finishInvocationViewRetirement159(); return }
        closeInvocationPayments180(clearOwnedToolSetFrame159())
    }
    private func finishInvocationViewRetirement159(): Unit {
        let returned = clearInvocationView159()
        // Private Context/control/getter aliases have left the complete clear
        // helper before either the parent's deferred or this child invoice.
        match (returned[1]) {
            case Some(parent) => closeInvocationPayments180(parent.returnRetainedInvocationChild159())
            case None => ()
        }
        closeInvocationPayments180((returned[0], returned[2]))
    }
    private func clearInvocationView159(): (?SharedToolSetSnapshot159, ?ToolInvocationContext, ?LogicalJsonOwnerReservation) {
        toolSnapshotLock159.lock()
        try {
            if (!invocationView159 || toolSnapshotReturned159) {
                return (None<SharedToolSetSnapshot159>, None<ToolInvocationContext>, None<LogicalJsonOwnerReservation>) }
            toolSnapshotReturned159 = true
            let returned = ownedToolSnapshot159
            let metadata = ownedInvocationData180; ownedInvocationData180 = None<LogicalJsonOwnerReservation>
            let parent = if (invocationRetained159) { invocationParent159 } else { None<ToolInvocationContext> }
            ownedToolSnapshot159 = None<SharedToolSetSnapshot159>; rawToolSnapshot159 = None<ToolSetSnapshot>
            invocationParent159 = None<ToolInvocationContext>; invocationRetained159 = false
            sequenceOwner = None<ToolInvocationContext>; clearPrivateInvocationData159()
            (returned, parent, metadata)
        } finally { toolSnapshotLock159.unlock() }
    }

    private func clearPrivateInvocationData159(): Unit {
        catalogInvocationRoot204 = None<ToolInvocationContext>
        invocationData_runId159 = None<RunId>
        invocationData_sessionId159 = None<SessionId>
        invocationData_epoch159 = None<Int64>
        invocationData_capabilities159 = None<CapabilitySet>
        invocationData_workspaceRoot159 = None<String>
        invocationData_cwd159 = None<String>
        invocationData_environment159 = None<ToolEnvironmentView>
        invocationData_cancellation159 = None<CancellationToken>
        invocationData_services159 = None<ToolServiceView>
        invocationData_executionSettings180 = None<AgentValue>
        invocationData_modelFaultCounters180 = None<Option<ModelStreamFaultCounters180>>
        invocationData_approvalModeOverride159 = None<InvocationValue_approvalModeOverride159>
        invocationData_outputSink159 = None<ToolOutputSink>
        invocationData_budget159 = None<ExecutionBudget>
        invocationData_budgetModeFn159 = None<InvocationValue_budgetModeFn159>
        invocationData_contextProjection159 = None<InvocationContextProjection>
        invocationData_trustedControl159 = None<Bool>
        invocationData_hostDocumentCommitParticipant159 = None<InvocationValue_hostDocumentCommitParticipant159>
        executionControlLock.lock()
        try {
            budgetChargeHandler = None<(BudgetCharge) -> Result<ExecutionUsage>>
            ownedTaskHandler = None<(String, Future<Unit>) -> Result<Unit>>
            nestedToolScheduler = None<(OperationId, () -> Result<Unit>) -> Result<Unit>>
            derivedToolFrameHandler = None<(OperationId, OperationId, String, Bool) -> Result<Unit>>
            paidExecutionFailureSink173 = None<PaidExecutionFailureSink173>
        } finally { executionControlLock.unlock() }
        // sequenceOwner links only bounded counters after owner retirement.
        // Derived/retained Contexts each fund that fixed carrier themselves;
        // no catalog, environment or control getter follows this path.
    }

    private func requireToolSnapshotFrame159(): Unit {
        if (invocationRevoked159 || toolSnapshotReturned159) {
            throw IllegalStateException("tool context snapshot frame has returned") }
    }
    public func permitsToolSnapshotThread159(thread: ThreadId): Bool {
        beginInvocationAction159()
        try { permitsToolSnapshotThread159Action159(thread) } finally { endInvocationAction159() }
    }

    private func permitsToolSnapshotThread159Action159(thread: ThreadId): Bool {
        requireLiveInvocationView159()
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            match (ownedToolSnapshot159) { case Some(value) => return value.permitsThread159(thread); case None => () }
            match (rawToolSnapshot159) {
                case Some(value) => toolSnapshotThreadAllowed(value, Some(thread))
                case None => true
            }
        } finally { toolSnapshotLock159.unlock() }
    }
    public func hasOwnedInvocationData180(): Bool {
        toolSnapshotLock159.lock(); try { requireToolSnapshotFrame159(); ownedInvocationData180.isSome() } finally { toolSnapshotLock159.unlock() }
    }
    public func hasOwnedToolSetSnapshot159(): Bool {
        beginInvocationAction159()
        try { hasOwnedToolSetSnapshot159Action159() } finally { endInvocationAction159() }
    }

    private func hasOwnedToolSetSnapshot159Action159(): Bool {
        requireLiveInvocationView159()
        toolSnapshotLock159.lock()
        try { requireToolSnapshotFrame159(); ownedToolSnapshot159.isSome() }
        finally { toolSnapshotLock159.unlock() }
    }
    public func hasToolSetSnapshot159(): Bool {
        beginInvocationAction159()
        try { hasToolSetSnapshot159Action159() } finally { endInvocationAction159() }
    }

    private func hasToolSetSnapshot159Action159(): Bool {
        requireLiveInvocationView159()
        toolSnapshotLock159.lock()
        try { requireToolSnapshotFrame159(); ownedToolSnapshot159.isSome() || rawToolSnapshot159.isSome() }
        finally { toolSnapshotLock159.unlock() }
    }
    public func hasMatchingToolHook159f(event: String, name: String): Bool {
        beginInvocationAction159()
        try { matchingToolHookFrame159f(event, name) } finally { endInvocationAction159() }
    }
    private func matchingToolHookFrame159f(event: String, name: String): Bool {
        requireLiveInvocationView159()
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            match (ownedToolSnapshot159) {
                case Some(value) => value.hasMatchingHook159f(event, name)
                case None => false
            }
        } finally { toolSnapshotLock159.unlock() }
    }
    public func copyOwnedMatchingHooks159f(event: String, toolName: String): ?OwnedToolHookSelection159f {
        beginInvocationAction159()
        try { copyOwnedMatchingHooksFrame159f(event, toolName) } finally { endInvocationAction159() }
    }
    private func copyOwnedMatchingHooksFrame159f(event: String, toolName: String): ?OwnedToolHookSelection159f {
        requireLiveInvocationView159()
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            match (ownedToolSnapshot159) {
                case Some(value) => value.copyMatchingHookHandlers159f(event, toolName)
                case None => None<OwnedToolHookSelection159f>
            }
        } finally { toolSnapshotLock159.unlock() }
    }
    public func forkOwnedToolSetSnapshot159(): ?SharedToolSetSnapshot159 {
        beginInvocationAction159()
        try { forkOwnedToolSetSnapshot159Action159() } finally { endInvocationAction159() }
    }

    private func forkOwnedToolSetSnapshot159Action159(): ?SharedToolSetSnapshot159 {
        requireLiveInvocationView159()
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            match (ownedToolSnapshot159) { case Some(value) => Some(value.fork159())
                case None => None<SharedToolSetSnapshot159> }
        } finally { toolSnapshotLock159.unlock() }
    }
    // The actual consumer calls this only after its complete helper/Future and
    // callbacks have returned. No arbitrary callback or Unit result calls it.
    public func returnOwnedToolSetFrame159(): Unit {
        requestInvocationRetirement159()
    }
    private func clearOwnedToolSetFrame159(): (?SharedToolSetSnapshot159, ?LogicalJsonOwnerReservation) {
        toolSnapshotLock159.lock()
        try {
            if (toolSnapshotReturned159) { return (None<SharedToolSetSnapshot159>, None<LogicalJsonOwnerReservation>) }
            let returned = ownedToolSnapshot159; ownedToolSnapshot159 = None<SharedToolSetSnapshot159>
            rawToolSnapshot159 = None<ToolSetSnapshot>; toolSnapshotReturned159 = true
            if (retainedInvocationChildren159 > 0) {
                deferredInvocationPayment159 = returned
                return (None<SharedToolSetSnapshot159>, None<LogicalJsonOwnerReservation>)
            }
            clearPrivateInvocationData159()
            let metadata = ownedInvocationData180; ownedInvocationData180 = None<LogicalJsonOwnerReservation>
            (returned, metadata)
        } finally { toolSnapshotLock159.unlock() }
    }

    // Numeric accounting only. A typed consumer cannot accidentally create a
    // historical raw graph merely to charge its independently retained input.
    public func closedToolSetRetainedCounts159(bytes: Int64, nodes: Int64): (Int64, Int64) {
        beginInvocationAction159()
        try { closedToolSetRetainedCountsAction159(bytes, nodes) }
        finally { endInvocationAction159() }
    }
    private func closedToolSetRetainedCountsAction159(bytes: Int64, nodes: Int64): (Int64, Int64) {
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            ownedToolSnapshot159.getOrThrow().retainedReferenceCounts159(bytes, nodes)
        } finally { toolSnapshotLock159.unlock() }
    }
    public func toolEntryDescriptionEquals159(index: Int64, expected: String): Bool {
        beginInvocationAction159()
        try { toolEntryDescriptionEqualsFrame159(index, expected) }
        finally { endInvocationAction159() }
    }
    private func toolEntryDescriptionEqualsFrame159(index: Int64, expected: String): Bool {
        toolSnapshotLock159.lock()
        try {
            requireToolSnapshotFrame159()
            match (ownedToolSnapshot159) {
                case Some(value) => value.entryDescriptionEquals159(index, expected)
                case None => rawToolSnapshot159.getOrThrow().entries[index].description == expected
            }
        } finally { toolSnapshotLock159.unlock() }
    }
    public func sameToolSetIdentity159(other: ToolInvocationContext): Bool {
        beginInvocationAction159()
        try { sameToolSetIdentityFrame159(other) }
        finally { endInvocationAction159() }
    }
    private func sameToolSetIdentityFrame159(other: ToolInvocationContext): Bool {
        let left = forkOwnedToolSetSnapshot159()
        try {
            let right = other.forkOwnedToolSetSnapshot159()
            try {
                match (left) {
                    case Some(first) => match (right) {
                        case Some(second) => first.identityEqualsShared159(second)
                        case None => first.identityEqualsValue159(other.legacyToolSetSnapshot159.getOrThrow().id)
                    }
                    case None => match (right) {
                        case Some(second) => second.identityEqualsValue159(legacyToolSetSnapshot159.getOrThrow().id)
                        case None => legacyToolSetSnapshot159.getOrThrow().id == other.legacyToolSetSnapshot159.getOrThrow().id
                    }
                }
            } finally { match (right) { case Some(value) => value.close159(); case None => () } }
        } finally { match (left) { case Some(value) => value.close159(); case None => () } }
    }
    public func sameToolSetSnapshot159(other: ToolInvocationContext): Bool {
        beginInvocationAction159()
        try { sameToolSetSnapshot159Action159(other) } finally { endInvocationAction159() }
    }

    private func sameToolSetSnapshot159Action159(other: ToolInvocationContext): Bool {
        requireLiveInvocationView159()
        let left = forkOwnedToolSetSnapshot159()
        try {
            // The other Context may be concurrently revoked. Its failed fork
            // must not strand the already acquired first independent share.
            let right = other.forkOwnedToolSetSnapshot159()
            try { sameContextToolSnapshotFrame159(this, other, left, right) }
            finally { match (right) { case Some(value) => value.close159(); case None => () } }
        } finally { match (left) { case Some(value) => value.close159(); case None => () } }
    }

    // This holds only a reference to the existing actual control/gateway.
    // No wrapper/captured callback is allocated and no Source is granted.
    public func bindPaidExecutionFailureSink173(sink: PaidExecutionFailureSink173): Unit {
        beginInvocationAction159()
        try { bindPaidExecutionFailureSink173Action159(sink) } finally { endInvocationAction159() }
    }

    private func bindPaidExecutionFailureSink173Action159(sink: PaidExecutionFailureSink173): Unit {
        requireLiveInvocationView159()
        executionControlLock.lock()
        try {
            if (paidExecutionFailureSink173.isNone()) { paidExecutionFailureSink173 = Some(sink) }
        } finally { executionControlLock.unlock() }
    }
    public func paidExecutionFailureConsumer173(): ?PaidExecutionFailureSink173 {
        beginInvocationAction159()
        try { paidExecutionFailureConsumer173Action159() } finally { endInvocationAction159() }
    }

    private func paidExecutionFailureConsumer173Action159(): ?PaidExecutionFailureSink173 {
        requireLiveInvocationView159()
        executionControlLock.lock()
        try { paidExecutionFailureSink173 } finally { executionControlLock.unlock() }
    }

    // AgentCore installs this once before publishing the context to tools so
    // nested calls charge and durably report against the owning Run ledger.
    public func setBudgetChargeHandler(
        handler: (BudgetCharge) -> Result<ExecutionUsage>
    ): Unit {
        beginInvocationAction159()
        try { setBudgetChargeHandlerAction159(handler) } finally { endInvocationAction159() }
    }

    private func setBudgetChargeHandlerAction159(
        handler: (BudgetCharge) -> Result<ExecutionUsage>
    ): Unit {
        requireLiveInvocationView159()
        executionControlLock.lock()
        try {
            if (budgetChargeHandler.isSome()) {
                throw IllegalStateException(
                    "tool invocation budget charge handler is already installed"
                )
            }
            budgetChargeHandler = Some(handler)
        } finally {
            executionControlLock.unlock()
        }
    }

    // Core installs the scheduler once. A parent Operation identity is
    // required so only a committed Program or plugin root can yield its slot.
    public func setNestedToolScheduler(
        handler: (OperationId, () -> Result<Unit>) -> Result<Unit>
    ): Unit {
        beginInvocationAction159()
        try { setNestedToolSchedulerAction159(handler) } finally { endInvocationAction159() }
    }

    private func setNestedToolSchedulerAction159(
        handler: (OperationId, () -> Result<Unit>) -> Result<Unit>
    ): Unit {
        requireLiveInvocationView159()
        executionControlLock.lock()
        try {
            if (nestedToolScheduler.isSome()) {
                throw IllegalStateException(
                    "tool invocation nested scheduler is already installed"
                )
            }
            nestedToolScheduler = Some(handler)
        } finally {
            executionControlLock.unlock()
        }
    }

    public func setDerivedToolFrameHandler(handler: (OperationId, OperationId, String, Bool) -> Result<Unit>): Unit {
        beginInvocationAction159()
        try { setDerivedToolFrameHandlerAction159(handler) } finally { endInvocationAction159() }
    }

    private func setDerivedToolFrameHandlerAction159(handler: (OperationId, OperationId, String, Bool) -> Result<Unit>): Unit {
        requireLiveInvocationView159()
        executionControlLock.lock()
        try {
            if (derivedToolFrameHandler.isSome()) { throw IllegalStateException("derived frame handler is already installed") }
            derivedToolFrameHandler = Some(handler)
        } finally { executionControlLock.unlock() }
    }

    // Used only by ToolPipeline after the sealed derived source, actual stored
    // plan and handoff have passed validation. A frame is not an admission.
    func executeDerivedFrame(prepared: PreparedToolInvocation,
        action: () -> Result<ToolResult>): Result<ToolResult> {
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            prepared.source.parentOperationId.isNone() || prepared.source.runId.value != runId.value ||
            prepared.source.sessionId.value != sessionId.value || prepared.source.epoch != epoch) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "tool.derived_frame_source_invalid",
                "derived frame requires the actual prepared source and context"))
        }
        executionControlLock.lock()
        let handler = try { derivedToolFrameHandler } finally { executionControlLock.unlock() }
        let enter = match (handler) {
            case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.scheduler_unavailable", "derived parent requires its actual scheduler frame"))
        }
        let parent = prepared.source.parentOperationId.getOrThrow()
        match (enter(parent, prepared.operationId, prepared.call.name, true)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        let outcome: Result<ToolResult> = try { action() } catch (_: Exception) {
            Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "tool.derived_executor_failed",
                "derived executor escaped after its actual handoff"))
        }
        match (enter(parent, prepared.operationId, prepared.call.name, false)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        outcome
    }

    // A host-created child may narrow capabilities, but it must retain the
    // exact Run/token/budget/workspace and frozen catalog view. No plugin frame
    // can install callbacks or manufacture the Prepared source above.
    public func inheritExecutionControlFrom(parent: ToolInvocationContext): Result<Unit> {
        beginInvocationAction159()
        try {
            parent.beginInvocationAction159()
            try {
                let outcome204 = inheritExecutionControlFromAction159(parent)
                match (outcome204) {
                    case Result.Ok(_) => inheritCatalogRootFrame204(parent)
                    case Result.Err(_) => () }
                outcome204
            } finally { parent.endInvocationAction159() }
        } finally { endInvocationAction159() }
    }

    private func inheritCatalogRootFrame204(parent: ToolInvocationContext): Unit {
        let original = parent.catalogRootFrame204()
        toolSnapshotLock159.lock()
        try { catalogInvocationRoot204 = Some(original) } finally { toolSnapshotLock159.unlock() }
    }

    private func inheritExecutionControlFromAction159(parent: ToolInvocationContext): Result<Unit> {
        requireLiveInvocationView159()
        if (refEq(this, parent) || trustedControl || runId.value != parent.runId.value || sessionId.value != parent.sessionId.value ||
            epoch != parent.epoch || !refEq(cancellation, parent.cancellation) || !refEq(budget, parent.budget) ||
            workspaceRoot != parent.workspaceRoot || cwd != parent.cwd ||
            approvalModeOverride != parent.approvalModeOverride || !refEq(contextProjection, parent.contextProjection) ||
            !sameDerivedOutputSink(outputSink, parent.outputSink) ||
            hasToolSetSnapshot159() != parent.hasToolSetSnapshot159()) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "tool.derived_context_mismatch",
                "derived execution must remain in its actual parent Run"))
        }
        if (hasToolSetSnapshot159() && !sameToolSetSnapshot159(parent)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "tool.derived_snapshot_mismatch",
                "derived execution cannot replace the parent catalog snapshot"))
        }
        let left = environment.entries(); let right = parent.environment.entries()
        if (left.size != right.size) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "tool.derived_context_mismatch", "derived environment differs")) }
        for (index in 0..left.size where left[index].name != right[index].name || left[index].value != right[index].value) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "tool.derived_context_mismatch", "derived environment differs"))
        }
        let leftServices = services.descriptors(); let rightServices = parent.services.descriptors()
        if (leftServices.size != rightServices.size) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "tool.derived_context_mismatch", "derived service view differs")) }
        for (index in 0..leftServices.size where leftServices[index].kind != rightServices[index].kind ||
            leftServices[index].name != rightServices[index].name || leftServices[index].version != rightServices[index].version) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "tool.derived_context_mismatch", "derived service view differs"))
        }
        for (cap in capabilities.values where !parent.capabilities.allows(cap.kind, resource: cap.resource)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "tool.derived_capability_widened", "derived capabilities exceed the parent"))
        }
        // Never hold two context locks. Configuration is immutable after the
        // host installs it, before the child becomes visible to an executor.
        parent.executionControlLock.lock()
        let (charge, tasks, scheduler, frame, paidFailure) = try {
            (parent.budgetChargeHandler, parent.ownedTaskHandler, parent.nestedToolScheduler, parent.derivedToolFrameHandler,
                parent.paidExecutionFailureSink173)
        } finally { parent.executionControlLock.unlock() }
        executionControlLock.lock()
        try {
            if (budgetChargeHandler.isSome() || ownedTaskHandler.isSome() || nestedToolScheduler.isSome() || derivedToolFrameHandler.isSome() || paidExecutionFailureSink173.isSome()) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "tool.derived_control_already_bound", "child already has execution control"))
            }
            budgetChargeHandler = charge; ownedTaskHandler = tasks
            nestedToolScheduler = scheduler; derivedToolFrameHandler = frame; paidExecutionFailureSink173 = paidFailure
            // A derived owner must not delegate its later sequence calls to a
            // transient executor/canonicalizer view that will be revoked.
            sequenceOwner = Some(parent.stableInvocationOwner159())
            Result.Ok(())
        } finally { executionControlLock.unlock() }
    }

    // Host composition installs the actual Run/epoch-bound owner once. This
    // is local code authority, never accepted from a plugin wire request.
    public func setOwnedTaskHandler(handler: (String, Future<Unit>) -> Result<Unit>): Unit {
        beginInvocationAction159()
        try { setOwnedTaskHandlerAction159(handler) } finally { endInvocationAction159() }
    }

    private func setOwnedTaskHandlerAction159(handler: (String, Future<Unit>) -> Result<Unit>): Unit {
        requireLiveInvocationView159()
        executionControlLock.lock()
        try {
            if (ownedTaskHandler.isSome()) { throw IllegalStateException("tool invocation task owner is already installed") }
            ownedTaskHandler = Some(handler)
        } finally { executionControlLock.unlock() }
    }

    public func ownTask(name: String, task: Future<Unit>): Result<Unit> {
        beginInvocationAction159()
        try { ownTaskAction159(name, task) } finally { endInvocationAction159() }
    }

    private func ownTaskAction159(name: String, task: Future<Unit>): Result<Unit> {
        requireLiveInvocationView159()
        executionControlLock.lock()
        let handler = try { ownedTaskHandler } finally { executionControlLock.unlock() }
        match (handler) {
            case Some(value) => value(name, task)
            case None => Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.task_owner_unavailable", "asynchronous tool work requires the actual owning Run"))
        }
    }

    public func chargeBudget(charge: BudgetCharge): Result<ExecutionUsage> {
        beginInvocationAction159()
        try { chargeBudgetAction159(charge) } finally { endInvocationAction159() }
    }

    private func chargeBudgetAction159(charge: BudgetCharge): Result<ExecutionUsage> {
        requireLiveInvocationView159()
        executionControlLock.lock()
        let handler = try {
            budgetChargeHandler
        } finally {
            executionControlLock.unlock()
        }
        match (handler) {
            case Some(value) => value(charge)
            case None => budget.reserve(charge)
        }
    }

    // The scheduler runs the callback without holding its coordination lock
    // or a store transaction; it returns the same exclusive Run slot after
    // the child settles.
    public func withNestedToolSlot(
        parentOperationId: OperationId,
        action: () -> Result<Unit>
    ): Result<Unit> {
        beginInvocationAction159()
        try { withNestedToolSlotAction159(parentOperationId, action) } finally { endInvocationAction159() }
    }

    private func withNestedToolSlotAction159(
        parentOperationId: OperationId,
        action: () -> Result<Unit>
    ): Result<Unit> {
        requireLiveInvocationView159()
        if (currentBudgetMode() == BudgetMode.Draining) {
            return Result.Err(AgentError(
                AgentErrorKind.BudgetExceeded,
                "budget.drain_exhausted",
                "nested tool work is not permitted while the run is draining"
            ))
        }
        executionControlLock.lock()
        let scheduler = try {
            nestedToolScheduler
        } finally {
            executionControlLock.unlock()
        }
        match (scheduler) {
            case Some(value) => value(parentOperationId, action)
            case None => Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.scheduler_unavailable",
                "nested tool execution requires the parent Run scheduler"
            ))
        }
    }

    private init(previous: ToolInvocationContext, rawSnapshot: ?ToolSetSnapshot,
        ownedSnapshot: ?SharedToolSetSnapshot159, projection: InvocationContextProjection) {
        this.invocationData_runId159 = Some(previous.runId)
        this.invocationData_sessionId159 = Some(previous.sessionId)
        this.invocationData_epoch159 = Some(previous.epoch)
        this.invocationData_capabilities159 = Some(previous.capabilities)
        this.invocationData_workspaceRoot159 = Some(previous.workspaceRoot)
        this.invocationData_cwd159 = Some(previous.cwd)
        this.invocationData_environment159 = Some(previous.environment)
        this.invocationData_cancellation159 = Some(previous.cancellation)
        this.invocationData_services159 = Some(previous.services)
        this.invocationData_executionSettings180 = Some(previous.executionSettings180)
        this.invocationData_modelFaultCounters180 = Some(previous.modelFaultCounters180)
        this.invocationData_approvalModeOverride159 = Some(previous.approvalModeOverride)
        this.invocationData_outputSink159 = Some(previous.outputSink)
        this.invocationData_budget159 = Some(previous.budget)
        this.invocationData_budgetModeFn159 = Some(previous.budgetModeFn)
        this.invocationData_contextProjection159 = Some(validatedContextSnapshot(projection))
        this.rawToolSnapshot159 = rawSnapshot
        this.ownedToolSnapshot159 = ownedSnapshot
        this.invocationData_trustedControl159 = Some(previous.trustedControl)
        this.invocationData_hostDocumentCommitParticipant159 = Some(None)
        this.sequence = 0
        this.sequenceOwner = match (previous.sequenceOwner) {
            case Some(value) => Some(value)
            case None => Some(previous.stableInvocationOwner159())
        }
    }

    // A new view cannot retarget any PreparedInvocation that holds the old view.
    // Core rebinds budget, single-slot and actual Run/epoch task ownership on
    // the new view; none are copied from an older context closure.
    public func withToolSetSnapshot(snapshot: ToolSetSnapshot): ToolInvocationContext {
        beginInvocationAction159()
        try { withToolSetSnapshotAction159(snapshot) } finally { endInvocationAction159() }
    }

    private func withToolSetSnapshotAction159(snapshot: ToolSetSnapshot): ToolInvocationContext {
        requireLiveInvocationView159()
        if (snapshot.threadId.isSome() && snapshot.threadId.getOrThrow().value != sessionId.value) {
            throw IllegalArgumentException("tool-set view belongs to another Thread")
        }
        ToolInvocationContext(this, Some(snapshot), None<SharedToolSetSnapshot159>, contextProjection)
    }

    public func withOwnedToolSetSnapshot159(snapshot: SharedToolSetSnapshot159): ToolInvocationContext {
        beginInvocationAction159()
        try { withOwnedToolSetSnapshot159Action159(snapshot) } finally { endInvocationAction159() }
    }

    private func withOwnedToolSetSnapshot159Action159(snapshot: SharedToolSetSnapshot159): ToolInvocationContext {
        requireLiveInvocationView159()
        if (!snapshot.permitsThread159(ThreadId(sessionId.value))) {
            throw IllegalArgumentException("tool-set view belongs to another Thread")
        }
        ToolInvocationContext(this, None<ToolSetSnapshot>, Some(snapshot), contextProjection)
    }

    public func withContextSnapshot(projection: InvocationContextProjection): ToolInvocationContext {
        beginInvocationAction159()
        try { withContextSnapshotAction159(projection) } finally { endInvocationAction159() }
    }

    private func withContextSnapshotAction159(projection: InvocationContextProjection): ToolInvocationContext {
        requireLiveInvocationView159()
        let owned = forkOwnedToolSetSnapshot159()
        match (owned) {
            case Some(_) => ToolInvocationContext(this, None<ToolSetSnapshot>, owned, projection)
            case None => ToolInvocationContext(this, Some(legacyToolSetSnapshot159.getOrThrow()), owned, projection)
        }
    }

    public func nextSequence(): Int64 {
        beginInvocationAction159()
        try { nextSequenceAction159() } finally { endInvocationAction159() }
    }

    private func nextSequenceAction159(): Int64 {
        requireLiveInvocationView159()
        nextSequenceData159()
    }

    private func nextSequenceData159(): Int64 {
        match (sequenceOwner) { case Some(value) => return value.nextSequenceData159(); case None => () }
        sequenceLock.lock()
        try {
            sequence += 1
            sequence
        } finally {
            sequenceLock.unlock()
        }
    }

    public func currentSequence(): Int64 {
        beginInvocationAction159()
        try { currentSequenceAction159() } finally { endInvocationAction159() }
    }

    private func currentSequenceAction159(): Int64 {
        requireLiveInvocationView159()
        currentSequenceData159()
    }

    private func currentSequenceData159(): Int64 {
        match (sequenceOwner) { case Some(value) => return value.currentSequenceData159(); case None => () }
        sequenceLock.lock()
        try {
            sequence
        } finally {
            sequenceLock.unlock()
        }
    }

    // Audit records form a distinct durable stream. They must not consume a
    // sequence number from the bounded Run journal, otherwise the App event
    // cursor observes artificial gaps for events it can never load.
    public func nextAuditSequence(): Int64 {
        beginInvocationAction159()
        try { nextAuditSequenceAction159() } finally { endInvocationAction159() }
    }

    private func nextAuditSequenceAction159(): Int64 {
        requireLiveInvocationView159()
        nextAuditSequenceData159()
    }

    private func nextAuditSequenceData159(): Int64 {
        match (sequenceOwner) { case Some(value) => return value.nextAuditSequenceData159(); case None => () }
        sequenceLock.lock()
        try {
            auditSequence += 1
            auditSequence
        } finally {
            sequenceLock.unlock()
        }
    }

    // BudgetMode of the run that owns this context; Normal when the creator
    // did not wire a live mode source (host-owned internal flows).
    public func currentBudgetMode(): BudgetMode {
        beginInvocationAction159()
        try { currentBudgetModeAction159() } finally { endInvocationAction159() }
    }

    private func currentBudgetModeAction159(): BudgetMode {
        requireLiveInvocationView159()
        match (budgetModeFn) {
            case Some(fn) => fn()
            case None => BudgetMode.Normal
        }
    }
}

// Interface values do not have an object identity. Such a value cannot
// claim to share the parent's output owner; retain the existing fail-closed rule.
func sameDerivedOutputSink(left: ToolOutputSink, right: ToolOutputSink): Bool {
    match (left as Object) {
        case Some(leftObject) => match (right as Object) {
            case Some(rightObject) => refEq(leftObject, rightObject)
            case None => false
        }
        case None => false
    }
}

// This helper returns only a scalar before either temporary share is closed.
// Raw identity checks apply solely to historical unowned fixture contexts.
private func sameContextToolSnapshotFrame159(left: ToolInvocationContext, right: ToolInvocationContext,
    leftShare: ?SharedToolSetSnapshot159, rightShare: ?SharedToolSetSnapshot159): Bool {
    if (leftShare.isSome() != rightShare.isSome()) { return false }
    if (leftShare.isSome()) { return leftShare.getOrThrow().sameBacking159(rightShare.getOrThrow()) }
    let leftRaw = left.legacyToolSetSnapshot159
    let rightRaw = right.legacyToolSetSnapshot159
    if (leftRaw.isSome() != rightRaw.isSome()) { return false }
    if (leftRaw.isNone()) { return true }
    refEq(leftRaw.getOrThrow(), rightRaw.getOrThrow())
}
