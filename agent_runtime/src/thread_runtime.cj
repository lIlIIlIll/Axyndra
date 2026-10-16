package agent_runtime

import yjson_support.*

import yjson.*

import std.sync.*
import std.collection.*
import agent_domain.*

private let ownedActiveRunFrames159 = OwnedActiveRunFrames159()

// Fixed control DATA only. No ModelLane, tool schema, catalog, new authority,
// String copy or graph share is produced by this scalar identity query.
public type ActiveRunControl159 = (ThreadId, SemanticTurnId, RunId, Int64,
    RunState, InvocationContextProjection, LaneId)

public class ActiveRunSnapshot {
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let lane: ModelLane
    private let viewLock159 = Mutex()
    private var ownedView159: ?OwnedActiveRunFrame159 = None<OwnedActiveRunFrame159>
    func bindOwnedView159(value: OwnedActiveRunFrame159): Unit {
        viewLock159.lock(); try { ownedView159 = Some(value) } finally { viewLock159.unlock() }
    }
    func clearOwnedView159(): Unit {
        viewLock159.lock(); try { ownedView159 = None<OwnedActiveRunFrame159> } finally { viewLock159.unlock() }
    }
    // Only a caller whose entire consuming helper has returned may clear this
    // independent view. Another snapshot has a separate lane and graph share.
    public func returnOwnedLaneView159(): Unit {
        let actual = try { viewLock159.lock(); ownedView159 } finally { viewLock159.unlock() }
        match (actual) { case Some(value) => value.returnActiveRunFrame159(); case None => () }
    }
    public func forkIndependentView159(): ActiveRunSnapshot {
        let independent = match (lane.forkOwnedLaneFrame159()) { case Some(value) => value; case None => lane }
        let copied = ActiveRunSnapshot(threadId, turnId, runId, epoch, independent,
            contextSnapshot, state, transitionSequence, executionLaneId: executionLaneId)
        let owner = OwnedActiveRunFrame159(copied)
        owner.snapshot159()
    }
    public let contextSnapshot: InvocationContextProjection
    public let state: RunState
    public let transitionSequence: Int64
    public let executionLaneId: LaneId

    public init(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        lane: ModelLane,
        contextSnapshot: InvocationContextProjection,
        state: RunState,
        transitionSequence: Int64,
        executionLaneId!: LaneId = LaneId("main")
    ) {
        this.threadId = threadId
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.lane = lane
        this.contextSnapshot = contextSnapshot
        this.state = state
        this.transitionSequence = transitionSequence
        this.executionLaneId = executionLaneId
    }
}

// An explicit DATA view of the live owner. Its ModelLane contains independent
// prepaid metadata and a snapshot share; it does not grant a Run/Source action.
// The ordinary historical activeRun API remains unchanged and unacknowledged.
public class OwnedActiveRunFrame159 {
    private let lock = Mutex()
    private var value: ?ActiveRunSnapshot
    private let registered159: Bool
    var debtNext159: ?OwnedActiveRunFrame159 = None<OwnedActiveRunFrame159>
    init(value: ActiveRunSnapshot) {
        this.value = Some(value)
        this.registered159 = value.lane.hasOwnedLaneFrame159()
        value.bindOwnedView159(this)
        // The view's original-bank prepaid header covers this intrusive node.
        // Unknown consumers stay strongly reachable until their actual return.
        // Historical raw fixtures have no original-bank graph reservation;
        // do not invent a permanently registered unpaid wrapper for them.
        if (registered159) { ownedActiveRunFrames159.retain159(this) }
    }
    public func snapshot159(): ActiveRunSnapshot {
        lock.lock(); try { value.getOrThrow() } finally { lock.unlock() }
    }
    public func returnActiveRunFrame159(): Unit {
        let returned = clearActiveRunFrame159()
        if (registered159) { ownedActiveRunFrames159.remove159(this) }
        match (returned) { case Some(lane) => lane.returnOwnedLaneFrame159(); case None => () }
    }
    private func clearActiveRunFrame159(): ?ModelLane {
        lock.lock()
        try {
            let lane = match (value) {
                case Some(current) => current.clearOwnedView159(); Some(current.lane)
                case None => None<ModelLane> }
            value = None<ActiveRunSnapshot>
            lane
        } finally { lock.unlock() }
    }
}

private class OwnedActiveRunFrames159 {
    private let lock = Mutex()
    private var head: ?OwnedActiveRunFrame159 = None<OwnedActiveRunFrame159>
    func retain159(value: OwnedActiveRunFrame159): Unit {
        lock.lock(); try { value.debtNext159 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: OwnedActiveRunFrame159): Unit {
        lock.lock()
        try {
            var prior: ?OwnedActiveRunFrame159 = None<OwnedActiveRunFrame159>
            var cursor = head
            while (cursor.isSome()) {
                let item = cursor.getOrThrow()
                if (refEq(item, value)) {
                    match (prior) { case Some(p) => p.debtNext159 = item.debtNext159
                        case None => head = item.debtNext159 }
                    item.debtNext159 = None<OwnedActiveRunFrame159>
                    return
                }
                prior = cursor; cursor = item.debtNext159
            }
        } finally { lock.unlock() }
    }
}

public class RuntimeSettlement {
    public let thread: AgentThreadSnapshot
    public let run: ActiveRunSnapshot
    public let joined: RunJoinReport
    private let returnWitness113: ?OwnedTaskReturnWitness113

    public func ownedTaskReturnWitness113(): ?OwnedTaskReturnWitness113 { returnWitness113 }

    public init(thread: AgentThreadSnapshot, run: ActiveRunSnapshot, joined: RunJoinReport,
        returnWitness113!: ?OwnedTaskReturnWitness113 = None<OwnedTaskReturnWitness113>) {
        this.thread = thread
        this.run = run
        this.joined = joined
        this.returnWitness113 = returnWitness113
    }
}

public class RuntimeOperationResolution {
    public let resolution: OperationResolution
    public let semanticCommit: ?SemanticCommitDecision

    public init(
        resolution: OperationResolution,
        semanticCommit!: ?SemanticCommitDecision = None
    ) {
        this.resolution = resolution
        this.semanticCommit = semanticCommit
    }
}

class OwnedActiveRun {
    let contextReadRequests = HashSet<String>()
    let contextReadCommitted = HashSet<String>()
    let turnId: SemanticTurnId
    let runId: RunId
    let epoch: Int64
    private var reservedViewLane159: ?ModelLane = None<ModelLane>
    func reserveOutwardView159(): Unit {
        if (reservedViewLane159.isNone()) {
            reservedViewLane159 = Some(match (lane.forkOwnedLaneFrame159()) {
                case Some(value) => value; case None => lane })
        }
    }
    func reservedOutwardView159(): ModelLane { reservedViewLane159.getOrThrow() }
    func clearReservedOutwardView159(): Unit { reservedViewLane159 = None<ModelLane> }
    private var laneData159: ?ModelLane
    mut prop lane: ModelLane {
        get() { laneData159.getOrThrow() }
        set(value) { laneData159 = Some(value) }
    }
    // Only after this actual Runtime owner has detached from active and all
    // outward snapshots already own independent shares. No Run state is ACK.
    func returnLaneRoot159(): Unit {
        let returned = clearLaneRootFrame159()
        match (returned) { case Some(value) => value.returnOwnedLaneFrame159(); case None => () }
    }
    private func clearLaneRootFrame159(): ?ModelLane {
        let value = laneData159; laneData159 = None<ModelLane>; value
    }
    var contextSnapshot: InvocationContextProjection
    var contextUpdate: ?RunContextUpdate = None
    let lifecycle: RunLifecycle
    let executionLaneId: LaneId
    let directAttestationAllowed: Bool
    let hostServiceOrigin: ?HostServiceOrigin
    let externalOrigin: ?ExternalCallOrigin
    let externalGuard: ?ExternalRequestGuard
    let managedJobOrigin: ?ManagedJobLaunchBinding
    let managedJobAdmission: ?ManagedJobAdmission
    var managedJobCallCommitted = false

    init(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        lane: ModelLane,
        contextSnapshot: InvocationContextProjection,
        lifecycle: RunLifecycle,
        executionLaneId!: LaneId = LaneId("main"),
        directAttestationAllowed!: Bool = true,
        hostServiceOrigin!: ?HostServiceOrigin = None,
        externalOrigin!: ?ExternalCallOrigin = None,
        externalGuard!: ?ExternalRequestGuard = None,
        managedJobOrigin!: ?ManagedJobLaunchBinding = None,
        managedJobAdmission!: ?ManagedJobAdmission = None,
        reservedViewLane159!: ?ModelLane = None<ModelLane>
    ) {
        this.reservedViewLane159 = reservedViewLane159
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.laneData159 = Some(lane)
        this.contextSnapshot = contextSnapshot
        this.lifecycle = lifecycle
        this.executionLaneId = executionLaneId
        this.directAttestationAllowed = directAttestationAllowed
        this.hostServiceOrigin = hostServiceOrigin
        this.externalOrigin = externalOrigin; this.externalGuard = externalGuard
        this.managedJobOrigin = managedJobOrigin; this.managedJobAdmission = managedJobAdmission
    }
}

public class RecoveredRunSpec {
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let state: RunState
    public let transitionSequence: Int64
    public let lane: ModelLane
    public let contextSnapshot: InvocationContextProjection
    public let deadlineMillis: Int64
    public let parentCancellation: ?CancellationToken
    public let executionLaneId: LaneId

    public init(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        state: RunState,
        transitionSequence: Int64,
        lane: ModelLane,
        contextSnapshot: InvocationContextProjection,
        deadlineMillis!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None,
        executionLaneId!: LaneId = LaneId("main")
    ) {
        if (epoch < 1 || transitionSequence < 0 || deadlineMillis < 0 ||
            (state != RunState.Running &&
            state != RunState.WaitingApproval &&
            state != RunState.WaitingExternal)) {
            throw IllegalArgumentException("recovered Run state is not safely resumable")
        }
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.state = state
        this.transitionSequence = transitionSequence
        this.lane = lane
        this.contextSnapshot = contextSnapshot
        this.deadlineMillis = deadlineMillis
        this.parentCancellation = parentCancellation
        this.executionLaneId = executionLaneId
    }
}

// AgentThreadRuntime is the only public mutable owner of a live Thread. The
// coordinator owns semantic commits; the RunLifecycle owns all async work;
// Each immutable ModelLane version changes only at a canonical safe cut; provider-neutral context snapshots stay fixed.
public class AgentThreadRuntime {
    private let hostOriginSeal = HostDirectOriginSeal()
    private let contextReadSeal = ContextReadSeal()
    private let externalOriginSeal = ExternalOriginSeal()
    private let lock = Mutex()
    private let coordinator: ThreadCoordinator
    private let projector: ContextProjector
    private let checkpointRepository: ?ContextCheckpointRepository
    private let knownParentHistoryEnabled: Bool
    private let nowMillis: () -> Int64
    private var active: ?OwnedActiveRun = None
    private var settling = false

    public init(
        coordinator: ThreadCoordinator,
        projector: ContextProjector,
        nowMillis: () -> Int64,
        checkpointRepository!: ?ContextCheckpointRepository = None,
        knownParentHistoryEnabled!: Bool = false
    ) {
        if (coordinator.snapshot().thread.activeTurnId.isSome()) {
            throw IllegalArgumentException(
                "recovered active Thread requires explicit reconciliation before Runtime start"
            )
        }
        this.coordinator = coordinator
        this.projector = projector
        this.checkpointRepository = checkpointRepository
        this.knownParentHistoryEnabled = knownParentHistoryEnabled
        this.nowMillis = nowMillis
    }

    // This constructor is intentionally separate: only a recovery coordinator
    // that has reconciled durable Operations should create a live owner.
    public init(
        coordinator: ThreadCoordinator,
        projector: ContextProjector,
        recovered: RecoveredRunSpec,
        nowMillis: () -> Int64,
        checkpointRepository!: ?ContextCheckpointRepository = None,
        knownParentHistoryEnabled!: Bool = false
    ) {
        let snapshot = coordinator.snapshot()
        if (snapshot.thread.activeTurnId.isNone() || snapshot.activeRunId.isNone() ||
            snapshot.thread.activeTurnId.getOrThrow().value != recovered.turnId.value ||
            snapshot.activeRunId.getOrThrow().value != recovered.runId.value ||
            snapshot.activeEpoch != recovered.epoch) {
            throw IllegalArgumentException("recovered Run does not own the active durable Thread")
        }
        this.coordinator = coordinator
        this.projector = projector
        this.checkpointRepository = checkpointRepository
        this.knownParentHistoryEnabled = knownParentHistoryEnabled
        this.nowMillis = nowMillis
        this.active = Some(OwnedActiveRun(
            recovered.turnId, recovered.runId, recovered.epoch,
            recovered.lane, recovered.contextSnapshot,
            RunLifecycle(
                deadlineMillis: recovered.deadlineMillis,
                parent: recovered.parentCancellation,
                initialState: recovered.state,
                transitionSequence: recovered.transitionSequence
            ),
            executionLaneId: recovered.executionLaneId,
            directAttestationAllowed: false,
            hostServiceOrigin: hostServiceOriginForRun(snapshot, recovered.turnId, recovered.runId),
            externalOrigin: externalOriginForRun(snapshot, recovered.turnId, recovered.runId),
            managedJobOrigin: managedJobOriginForRun(snapshot, recovered.turnId, recovered.runId)
        ))
    }

    public func threadSnapshot(): AgentThreadSnapshot { coordinator.snapshot() }
    public func hasRetainedQueuedInputCache113(): Bool { coordinator.hasRetainedQueuedInputCache113() }
    // Complete conversation data is borrowed from the actual Store row owner.
    // Metadata/canonical retirement are distinct from legacy raw history.
    public func enableOwnedCanonicalReadback(readback: OwnedCanonicalThreadReadback,
        allocate: (Int64) -> LogicalJsonOwnerReservation): Result<Unit> {
        coordinator.enableOwnedCanonicalReadback(readback, allocate)
    }
    public func ownedCanonicalReadback(): ?OwnedCanonicalThreadReadback { coordinator.ownedCanonicalReadback() }
    public func threadMetadataSnapshot(): AgentThreadSnapshot { coordinator.metadataSnapshot() }
    // For control/footer-only callers. Complete data consumers remain on
    // explicit paid readback; ordinary callers still use the original snapshot.
    private func controlMetadataSnapshot(): AgentThreadSnapshot {
        if (coordinator.ownedCanonicalReadback().isSome()) { coordinator.metadataSnapshot() }
        else { coordinator.snapshot() }
    }

    public func takeOwnedCanonicalRetirement(lease: ToolResultPayloadLease): Result<OwnedCanonicalResultRetirement> {
        coordinator.takeOwnedCanonicalRetirement(lease)
    }
    public func projectOwnedContext(lane: ModelLane, checkpoint: ?ContextCheckpoint,
        dynamicState: AgentValue, allocate: (Int64) -> LogicalJsonOwnerReservation,
        guard: () -> Result<Unit>): Result<OwnedModelContextProjection> {
        let reader = match (coordinator.ownedCanonicalReadback()) {
            case Some(actual) => actual
            case None => return runtimeConflict("context.owned_readback_missing", "actual complete paid history readback is not installed") }
        let metadata = coordinator.metadataSnapshot()
        projector.projectOwned(metadata.thread, reader, lane, checkpoint, dynamicState, allocate, guard)
    }


    public func appendUserInput(
        itemId: ItemId,
        content: ThreadItemContent,
        provenance: ItemProvenance,
        createdAtMillis: Int64
    ): Result<ThreadItem> {
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            match (active) {
                case Some(value) => coordinator.appendUserInput(
                    value.turnId,
                    value.runId,
                    itemId,
                    content,
                    provenance,
                    createdAtMillis
                )
                case None => runtimeConflict(
                    "runtime.no_active_run",
                    "user input requires an active Run"
                )
            }
        } finally {
            lock.unlock()
        }
    }

    // Exact-once external delivery boundary. A live Run owns the input when
    // present; otherwise the coordinator atomically records a completed
    // delivery Turn. Replays are accepted only when identity and payload are
    // byte-for-byte identical.
    public func appendExternalUserTextOnce(
        identity: String,
        text: String,
        source!: String = "external",
        createdAtMillis!: Int64 = 0
    ): Result<Bool> {
        let normalized = identity.trimAscii()
        if (normalized == "" || text == "" || source.trimAscii() == "") {
            return runtimeConflict(
                "runtime.external_input_invalid",
                "external input requires identity, source, and text"
            )
        }
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            let itemId = ItemId("external-item-" + normalized)
            let snapshot = coordinator.snapshot()
            for (item in snapshot.items where item.id.value == itemId.value) {
                if (exactExternalText(item, text, source.trimAscii())) {
                    return Result.Ok(false)
                }
                return runtimeConflict(
                    "runtime.external_input_collision",
                    "external input identity is bound to a different payload"
                )
            }
            let content = ThreadItemContent.UserMessage(textMessageParts(text))
            match (active) {
                case Some(value) => match (coordinator.appendUserInput(
                    value.turnId,
                    value.runId,
                    itemId,
                    content,
                    ItemProvenance(source, runId: Some(value.runId)),
                    createdAtMillis
                )) {
                    case Result.Ok(_) => Result.Ok(true)
                    case Result.Err(error) => Result.Err(error)
                }
                case None =>
                    let deliveryRunId = RunId("external-run-" + normalized)
                    match (coordinator.appendExternalInput(
                        SemanticTurnId("external-turn-" + normalized),
                        deliveryRunId,
                        itemId,
                        content,
                        ItemProvenance(source, runId: Some(deliveryRunId)),
                        createdAtMillis
                    )) {
                        case Result.Ok(_) => Result.Ok(true)
                        case Result.Err(error) => Result.Err(error)
                    }
            }
        } finally {
            lock.unlock()
        }
    }

    // The old snapshot is a CAS token, never an instruction to replay old work.
    // A failed durable commit leaves both the lane and Thread revision unchanged.
    public func replaceToolSetAtSafeCut(
        expectedRun: RunId, expectedEpoch: Int64,
        expectedLane: ModelLane, replacement: ToolSetSnapshot,
        coreBoundary!: ?AgentValue = None
    ): Result<ActiveRunSnapshot> {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return Result.Err(modelLaneCutError("run.model_lane_cut_conflict", "Run is not active"))
            }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || state != RunState.Running || owned.lifecycle.scope.token.isCancelled() ||
                owned.hostServiceOrigin.isSome() || owned.externalOrigin.isSome() || owned.managedJobOrigin.isSome() ||
                owned.runId.value != expectedRun.value || owned.epoch != expectedEpoch ||
                canonicalAgentValue(modelLaneSnapshotValue(owned.lane)) !=
                    canonicalAgentValue(modelLaneSnapshotValue(expectedLane))) {
                return Result.Err(modelLaneCutError("run.model_lane_cut_conflict",
                    "Model lane changed or Run is not at an owned model boundary"))
            }
            if (owned.lifecycle.scope.hasPendingModelBoundaryTask()) {
                return runtimeConflict("run.model_lane_cleanup_pending", "Owned model resources have not acknowledged cleanup")
            }
            let change = try { RunModelLaneChange(owned.lane,
                modelLaneReplacingToolSet(owned.lane, replacement), nowMillis(), coreBoundary: coreBoundary) }
                catch (_: Exception) { return Result.Err(modelLaneCutError(
                    "run.model_lane_cut_invalid", "Replacement tool snapshot is invalid")) }
            match (coordinator.replaceModelLaneAtSafeCut(expectedRun, expectedEpoch, change)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) =>
                    owned.lane = change.nextLane()
                    Result.Ok(activeSnapshot(owned))
            }
        } finally { lock.unlock() }
    }

    public func replaceOwnedToolSetAtSafeCut159(expectedRun: RunId, expectedEpoch: Int64,
        expectedLane: ModelLane, replacement: SharedToolSetSnapshot159,
        coreBoundary!: ?AgentValue = None): Result<ActiveRunSnapshot> {
        let answer = replaceOwnedToolSetFrame159(expectedRun, expectedEpoch, expectedLane, replacement, coreBoundary)
        match (answer[1]) { case Some(lane) => lane.returnOwnedLaneFrame159(); case None => () }
        answer[0]
    }
    private func replaceOwnedToolSetFrame159(expectedRun: RunId, expectedEpoch: Int64,
        expectedLane: ModelLane, replacement: SharedToolSetSnapshot159,
        coreBoundary: ?AgentValue): (Result<ActiveRunSnapshot>, ?ModelLane) {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return (Result.Err(modelLaneCutError("run.model_lane_cut_conflict", "Run is not active")), None<ModelLane>)
            }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || state != RunState.Running || owned.lifecycle.scope.token.isCancelled() ||
                owned.hostServiceOrigin.isSome() || owned.externalOrigin.isSome() || owned.managedJobOrigin.isSome() ||
                owned.runId.value != expectedRun.value || owned.epoch != expectedEpoch ||
                !owned.lane.snapshotEqualsLane159(expectedLane)) {
                return (Result.Err(modelLaneCutError("run.model_lane_cut_conflict",
                    "Model lane changed or Run is not at an owned model boundary")), None<ModelLane>)
            }
            if (owned.lifecycle.scope.hasPendingModelBoundaryTask()) {
                return (runtimeConflict<ActiveRunSnapshot>("run.model_lane_cleanup_pending", "Owned model resources have not acknowledged cleanup"), None<ModelLane>)
            }
            let next = try { modelLaneReplacingSharedToolSet159(owned.lane, replacement) }
                catch (_: Exception) { return (Result.Err(modelLaneCutError(
                    "run.model_lane_cut_invalid", "Replacement tool snapshot is invalid")), None<ModelLane>) }
            match (commitOwnedModelLaneCut159(expectedRun, expectedEpoch, owned.lane, next, coreBoundary: coreBoundary)) {
                case Result.Err(error) => (Result.Err(error), Some(next))
                case Result.Ok(_) =>
                    let prior = owned.lane; owned.lane = next
                    (Result.Ok(activeSnapshot(owned)), Some(prior))
            }
        } finally { lock.unlock() }
    }
    private func commitOwnedModelLaneCut159(expectedRun: RunId, expectedEpoch: Int64,
        previous: ModelLane, next: ModelLane, previousContext!: ?InvocationContextProjection = None,
        nextContext!: ?InvocationContextProjection = None, contextFacts!: Array<ContextReadFactLink> = [],
        coreBoundary!: ?AgentValue = None): Result<Unit> {
        let before = previous.ownedSnapshotValue159().getOrThrow()
        let after = next.ownedSnapshotValue159().getOrThrow()
        let input = OwnedModelLaneCut159(before, after)
        let result = commitOwnedModelLaneCutFrame159(expectedRun, expectedEpoch, input,
            previousContext, nextContext, contextFacts, coreBoundary)
        input.returnConsumerFrame159()
        result
    }
    private func commitOwnedModelLaneCutFrame159(expectedRun: RunId, expectedEpoch: Int64,
        input: OwnedModelLaneCut159, previousContext: ?InvocationContextProjection,
        nextContext: ?InvocationContextProjection, contextFacts: Array<ContextReadFactLink>,
        coreBoundary: ?AgentValue): Result<Unit> {
        let change = try { RunModelLaneChange(input, nowMillis(), previousContext: previousContext,
            nextContext: nextContext, contextFacts: contextFacts, coreBoundary: coreBoundary) }
            catch (_: Exception) { return Result.Err(modelLaneCutError(
                "run.model_lane_cut_invalid", "Replacement tool snapshot is invalid")) }
        input.install159(change)
        coordinator.replaceModelLaneAtSafeCut(expectedRun, expectedEpoch, change, ownedInput: Some(input))
    }

    // Host-only data update. No pending value is reconstructed from history.
    public func queueContextSnapshot(expectedRun: RunId, expectedEpoch: Int64,
        expectedDigest: String, replacement: InvocationContextProjection,
        validity!: () -> Result<Unit> = { => Result.Ok(()) }, facts!: Array<ContextReadFactLink> = []): Result<RunContextUpdate> {
        let frozen = try { validatedContextSnapshot(replacement) } catch (_: Exception) {
            return runtimeConflict("context.update_invalid", "context snapshot is malformed or oversized") }
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return runtimeConflict("context.update_stale", "Run is not active") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            match (owned.contextUpdate) { case Some(value) =>
                if (value.state() == ContextUpdateState.Discarded) { owned.contextUpdate = None }
                case None => () }
            if (settling || owned.lifecycle.scope.token.isCancelled() ||
                (state != RunState.Running && state != RunState.WaitingApproval) ||
                owned.runId.value != expectedRun.value || owned.epoch != expectedEpoch ||
                owned.hostServiceOrigin.isSome() || owned.externalOrigin.isSome() || owned.managedJobOrigin.isSome() ||
                contextReadProjectionDigest(owned.contextSnapshot) != expectedDigest ||
                contextReadProjectionDigest(frozen) == expectedDigest || owned.contextUpdate.isSome()) {
                return runtimeConflict("context.update_stale", "context update lost its Run, epoch or expected projection") }
            let update = try { RunContextUpdate(owned.runId, owned.epoch, owned.contextSnapshot, frozen, validity, facts) }
                catch (_: Exception) { return runtimeConflict("context.update_facts_invalid", "context update fact links are malformed") }
            owned.contextUpdate = Some(update)
            Result.Ok(update)
        } finally { lock.unlock() }
    }

    public func applyContextSnapshotAtSafeCut(expectedRun: RunId, expectedEpoch: Int64,
        coreBoundary!: ?(() -> AgentValue) = None): Result<ActiveRunSnapshot> {
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return runtimeConflict("context.update_stale", "Run is not active") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || state != RunState.Running || owned.lifecycle.scope.token.isCancelled() ||
                owned.runId.value != expectedRun.value || owned.epoch != expectedEpoch ||
                owned.hostServiceOrigin.isSome() || owned.externalOrigin.isSome() || owned.managedJobOrigin.isSome()) {
                return runtimeConflict("context.update_not_at_cut", "Run does not own a settled model boundary") }
            let update = match (owned.contextUpdate) { case Some(value) => value
                case None => return Result.Ok(activeSnapshot(owned)) }
            if (update.state() == ContextUpdateState.Discarded) {
                owned.contextUpdate = None; return Result.Ok(activeSnapshot(owned)) }
            if (owned.lifecycle.scope.hasPendingModelBoundaryTask()) {
                return runtimeConflict("context.update_not_at_cut", "Run still owns model-boundary cleanup") }
            let result = update.commit({ =>
                if (update.runId.value != owned.runId.value || update.epoch != owned.epoch ||
                    update.previousDigest != contextReadProjectionDigest(owned.contextSnapshot)) {
                    return runtimeConflict("context.update_stale", "queued context no longer matches this Run") }
                // Capture only an actual accepted update under the original
                // owner/cancellation/cleanup checks, before the same cut TX.
                let frozenBoundary: ?AgentValue = try { match (coreBoundary) {
                    case Some(capture) => Some(capture()); case None => None<AgentValue> } }
                    catch (error: Exception) { return runtimeConflict("context.boundary_snapshot_invalid", error.message) }
                if (owned.lane.hasOwnedLaneFrame159()) {
                    return commitOwnedModelLaneCut159(expectedRun, expectedEpoch, owned.lane, owned.lane,
                        previousContext: Some(owned.contextSnapshot), nextContext: Some(update.nextSnapshot()),
                        contextFacts: update.facts(), coreBoundary: frozenBoundary)
                }
                let change = RunModelLaneChange(owned.lane, owned.lane, nowMillis(),
                    previousContext: Some(owned.contextSnapshot), nextContext: Some(update.nextSnapshot()), contextFacts: update.facts(), coreBoundary: frozenBoundary)
                coordinator.replaceModelLaneAtSafeCut(expectedRun, expectedEpoch, change)
            })
            owned.contextUpdate = None
            match (result) {
                case Result.Err(error) =>
                    // Revoked/withdrawn data never changes the actual version.
                    // A failed durable CAS remains a visible error to Core.
                    if (error.code == "context.update_discarded" || error.code == "context.update_source_stale") {
                        return Result.Ok(activeSnapshot(owned)) }
                    Result.Err(error)
                case Result.Ok(_) =>
                    owned.contextSnapshot = update.nextSnapshot()
                    Result.Ok(activeSnapshot(owned))
            }
        } finally { lock.unlock() }
    }

    public func hasActiveRun159(): Bool {
        lock.lock(); try { active.isSome() } finally { lock.unlock() }
    }
    public func activeRunControl159(): ?ActiveRunControl159 {
        lock.lock()
        try {
            match (active) {
                case None => None<ActiveRunControl159>
                case Some(value) =>
                    let (state, _) = value.lifecycle.machine.snapshot()
                    Some((coordinator.metadataSnapshot().thread.id, value.turnId,
                        value.runId, value.epoch, state, value.contextSnapshot, value.executionLaneId))
            }
        } finally { lock.unlock() }
    }
    public func activeRunOwned159(): ?OwnedActiveRunFrame159 {
        lock.lock()
        try {
            match (active) {
                case None => None<OwnedActiveRunFrame159>
                case Some(value) =>
                    Some(activeOwnedSnapshot159(value))
            }
        } finally { lock.unlock() }
    }
    public func activeRun(): ?ActiveRunSnapshot {
        lock.lock()
        try {
            match (active) {
                case Some(value) => Some(activeSnapshot(value))
                case None => None
            }
        } finally {
            lock.unlock()
        }
    }

    // TaskRuntime calls this only while executing the approved launch parent.
    // Store I/O and source callbacks run outside the Runtime lock. Store repeats
    // current Run/epoch/plan/handoff checks in its own existing transaction.
    public func reserveManagedJob(source: OperationRootSource, operationId: OperationId,
        plan: NormalizedOperationPlan, operations: OperationRuntimePort,
        expectedRunId: RunId, expectedEpoch: Int64): Result<ManagedJobReservation> {
        if (!isManagedJobLaunchPlan(plan)) { return managedJobDenied("task.managed_job_plan_invalid") }
        let declaration = try { managedJobDeclarationFromValue(plan.canonicalArguments.field("host_plan").getOrThrow()
            .field("managed_job").getOrThrow()) } catch (_: Exception) { return managedJobDenied("task.managed_job_plan_invalid") }
        match (source) {
            case OperationRootSource.Direct(value) => match (value.origin) {
                case DirectCallOrigin.UserDirect => ()
                case _ => return managedJobDenied("task.managed_job_origin_unsupported")
            }
            case OperationRootSource.Committed(_) => ()
        }
        lock.lock()
        let parentToken: CancellationToken = try {
            let owned = match (active) { case Some(value) => value
                case None => return managedJobDenied("task.managed_job_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || !owned.directAttestationAllowed || state != RunState.Running ||
                owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch ||
                owned.hostServiceOrigin.isSome() || owned.externalOrigin.isSome() || owned.managedJobOrigin.isSome() ||
                owned.lifecycle.scope.token.isCancelled(nowMillis: nowMillis())) {
                return managedJobDenied("task.managed_job_owner_inactive")
            }
            let deadline = owned.lifecycle.scope.token.deadlineMillis
            if (declaration.deadlineMillis <= nowMillis() || declaration.deadlineMillis - nowMillis() > 3600000 ||
                (deadline > 0 && declaration.deadlineMillis > deadline)) {
                return managedJobDenied("task.managed_job_deadline_invalid")
            }
            owned.lifecycle.scope.token
        } finally { lock.unlock() }
        let snapshot = controlMetadataSnapshot()
        let binding = match (operations.reserveManagedJobLaunch(source, operationId, expectedRunId,
            snapshot.thread.id, expectedEpoch, plan)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        // The returned description must be exactly the request sent to Store.
        let requested = declaration
        if (binding.parentOperationId.value != operationId.value || binding.parentRunId.value != expectedRunId.value ||
            binding.parentEpoch != expectedEpoch || binding.parentThreadId.value != snapshot.thread.id.value ||
            binding.parentItemId.value != source.itemId().value || binding.parentCallId != source.callId() ||
            canonicalAgentValue(managedJobDeclarationValue(requested)) != canonicalAgentValue(managedJobDeclarationValue(binding.declaration))) {
            return managedJobDenied("task.managed_job_store_binding_invalid")
        }
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return managedJobDenied("task.managed_job_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || state != RunState.Running || owned.runId.value != expectedRunId.value ||
                owned.epoch != expectedEpoch || !refEq(parentToken, owned.lifecycle.scope.token) || parentToken.isCancelled(nowMillis: nowMillis())) {
                return managedJobDenied("task.managed_job_owner_inactive")
            }
            Result.Ok(ManagedJobReservation(binding, operations, parentToken, nowMillis))
        } finally { lock.unlock() }
    }

    public func startTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        userItemId: ItemId,
        userContent: ThreadItemContent,
        lane: ModelLane,
        contextSnapshot: InvocationContextProjection,
        createdAtMillis!: Int64 = 0,
        deadlineMillis!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None,
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main"),
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    ): Result<ActiveRunSnapshot> {
        startTurnOwned(turnId, runId, userItemId, userContent, lane, contextSnapshot,
            createdAtMillis: createdAtMillis, deadlineMillis: deadlineMillis,
            parentCancellation: parentCancellation, runBudgetSnapshot: runBudgetSnapshot,
            executionLaneId: executionLaneId, queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113)
    }

    private func startTurnOwned(
        turnId: SemanticTurnId,
        runId: RunId,
        userItemId: ItemId,
        userContent: ThreadItemContent,
        lane: ModelLane,
        contextSnapshot: InvocationContextProjection,
        createdAtMillis!: Int64 = 0,
        deadlineMillis!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None,
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main"),
        hostServiceOrigin!: ?HostServiceOrigin = None,
        externalOrigin!: ?ExternalCallOrigin = None,
        externalGuard!: ?ExternalRequestGuard = None,
        managedJobAdmission!: ?ManagedJobAdmission = None,
        internalModelMaintenance!: Bool = false,
        continuationAdmission!: ?ContinuationRunAdmission = None,
        continuationRequest!: AgentValue = nullValue(),
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    ): Result<ActiveRunSnapshot> {
        let persistedContext = try { contextSnapshotValue(contextSnapshot) } catch (_: Exception) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "context.snapshot_invalid",
                "Run context exceeds the supported immutable snapshot envelope"))
        }
        lock.lock()
        try {
            if (active.isSome()) {
                return runtimeConflict("runtime.run_already_active", "Thread already has an active Run")
            }
            // Reserve and copy the Runtime's own lane before lifecycle/SQL
            // admission. The argument remains a distinct caller-owned frame.
            let runtimeLane159 = match (lane.forkOwnedLaneFrame159()) {
                case Some(value) => value; case None => lane }
            let initialViewLane159 = match (lane.forkOwnedLaneFrame159()) {
                case Some(value) => value; case None => lane }
            let lifecycle = RunLifecycle(deadlineMillis: deadlineMillis, parent: parentCancellation)
            let thread = match (coordinator.startOwnedTurnWithLane159(
                turnId, runId, userItemId, userContent,
                createdAtMillis: createdAtMillis,
                lane159: lane,
                runContextSnapshot: persistedContext,
                runBudgetSnapshot: runBudgetSnapshot,
                executionLaneId: executionLaneId, hostServiceOrigin: hostServiceOrigin, externalOrigin: externalOrigin,
                internalModelMaintenance: internalModelMaintenance, continuationAdmission: continuationAdmission, continuationRequest: continuationRequest,
                queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113,
                managedJobOrigin: match (managedJobAdmission) { case Some(value) => Some(value.binding); case None => None }
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let runningProposal = match (lifecycle.machine.preview(RunState.Running)) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    let _ = coordinator.failTurn(turnId, runId, thread.activeEpoch)
                    return Result.Err(error)
            }
            match (coordinator.recordRunTransition(
                turnId, runId, thread.activeEpoch, runningProposal, nowMillis()
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    let _ = coordinator.failTurn(turnId, runId, thread.activeEpoch)
                    return Result.Err(error)
            }
            let _ = lifecycle.machine.commitPreview(runningProposal).value().getOrThrow()
            let owned = OwnedActiveRun(
                turnId, runId, thread.activeEpoch, runtimeLane159, contextSnapshot, lifecycle,
                executionLaneId: executionLaneId, hostServiceOrigin: hostServiceOrigin,
                externalOrigin: externalOrigin, externalGuard: externalGuard,
                managedJobOrigin: match (managedJobAdmission) { case Some(value) => Some(value.binding); case None => None },
                managedJobAdmission: managedJobAdmission,
                reservedViewLane159: Some(initialViewLane159)
            )
            active = Some(owned)
            Result.Ok(reservedActiveSnapshot159(owned))
        } finally {
            lock.unlock()
        }
    }

    // Host-owned continuation uses the same RunLifecycle and canonical Turn.
    // No Operation/Direct origin is invented, and no owner can be restored from
    // the initiator description. Core supplies its exact frozen request digest.
    public func startContinuationTurn(admission: ContinuationRunAdmission, requestSnapshot: AgentValue,
        lane: ModelLane, contextSnapshot: InvocationContextProjection, runBudgetSnapshot: AgentValue,
        createdAtMillis!: Int64 = 0, deadlineMillis!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None): Result<ActiveRunSnapshot> {
        let origin = admission.origin
        let frozenRequest = parseUnifiedJson(stringifyUnifiedJson(requestSnapshot), maxBytes: 8388608)
        if (modelPolicySha256Text(canonicalAgentValue(frozenRequest)) != origin.requestDigest ||
            !lane.continuationLaunchDigestEquals159(contextSnapshotValue(contextSnapshot), runBudgetSnapshot, origin.launchDigest)) {
            return continuationDenied("continuation.request_changed")
        }
        admission.start({ => startTurnOwned(SemanticTurnId(origin.turnId), RunId(origin.runId), ItemId(origin.initiatorItemId),
            ThreadItemContent.SystemNote("Host continuation"), lane, contextSnapshot,
            createdAtMillis: createdAtMillis, deadlineMillis: deadlineMillis, parentCancellation: parentCancellation,
            runBudgetSnapshot: runBudgetSnapshot, executionLaneId: LaneId(origin.laneId), continuationAdmission: Some(admission), continuationRequest: frozenRequest) })
    }

    // Core-only composition entry. This creates an actual zero-Tool maintenance
    // Run; it neither reuses a completed Run nor bypasses active Thread admission.
    public func startInternalModelTurn(turnId: SemanticTurnId, runId: RunId, initiatorItemId: ItemId,
        lane: ModelLane, contextSnapshot: InvocationContextProjection, createdAtMillis: Int64,
        deadlineMillis: Int64, runBudgetSnapshot: AgentValue,
        executionLaneId!: LaneId = LaneId("main"), parentCancellation!: ?CancellationToken = None): Result<ActiveRunSnapshot> {
        if (lane.role != ModelLaneRole.Compactor || !lane.hasNoToolEntriesOrHooks159()) {
            return runtimeConflict("model.maintenance_tools_forbidden", "model maintenance has no Tool directory")
        }
        startTurnOwned(turnId, runId, initiatorItemId,
            ThreadItemContent.SystemNote("Model maintenance: context_compaction"), lane, contextSnapshot,
            createdAtMillis: createdAtMillis, deadlineMillis: deadlineMillis,
            runBudgetSnapshot: runBudgetSnapshot, executionLaneId: executionLaneId,
            internalModelMaintenance: true, parentCancellation: parentCancellation)
    }

    // A successful parent launch delegates exactly one command to this real
    // child Thread/Run. It never fabricates a user message or model Decision.
    public func startManagedJobTurn(admission: ManagedJobAdmission, turnId: SemanticTurnId, initiatorItemId: ItemId,
        lane: ModelLane, contextSnapshot: InvocationContextProjection,
        createdAtMillis!: Int64 = 0): Result<ActiveRunSnapshot> {
        match (admission.reserveOwner(controlMetadataSnapshot().thread.id)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let job = admission.binding.declaration
        let started = match (startTurnOwned(turnId, job.runId, initiatorItemId,
            ThreadItemContent.SystemNote("Managed job: " + job.jobId), lane, contextSnapshot,
            createdAtMillis: createdAtMillis, deadlineMillis: job.deadlineMillis,
            parentCancellation: Some(admission.cancellationToken),
            runBudgetSnapshot: managedJobRunBudget(admission.binding),
            managedJobAdmission: Some(admission))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return managedJobDenied("task.managed_job_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || !owned.directAttestationAllowed || state != RunState.Running ||
                owned.runId.value != started.runId.value || owned.epoch != started.epoch ||
                owned.managedJobAdmission.isNone() || !refEq(owned.managedJobAdmission.getOrThrow(), admission) ||
                owned.lifecycle.scope.token.isCancelled(nowMillis: nowMillis())) {
                return managedJobDenied("task.managed_job_owner_inactive")
            }
            admission.bindOwner({ => validateManagedJobOwner(admission, started.runId, started.epoch) }, owned.lifecycle.scope.token)
            Result.Ok(started)
        } finally { lock.unlock() }
    }

    private func validateManagedJobOwner(admission: ManagedJobAdmission, runId: RunId, epoch: Int64): Result<Unit> {
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value; case None => return managedJobDenied("task.managed_job_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || !owned.directAttestationAllowed || state != RunState.Running || owned.runId.value != runId.value ||
                owned.epoch != epoch || owned.managedJobAdmission.isNone() || !refEq(owned.managedJobAdmission.getOrThrow(), admission) ||
                owned.lifecycle.scope.token.isCancelled(nowMillis: nowMillis())) { return managedJobDenied("task.managed_job_owner_inactive") }
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func commitManagedJobToolCall(admission: ManagedJobAdmission, itemId: ItemId, operationId: OperationId,
        call: ToolCall, expectedRunId: RunId, expectedEpoch: Int64, createdAtMillis!: Int64 = 0): Result<DirectToolCallRef> {
        match (admission.validateInvocation(call)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value; case None => return managedJobDenied("task.managed_job_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || !owned.directAttestationAllowed || state != RunState.Running || owned.managedJobCallCommitted ||
                owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch || owned.managedJobAdmission.isNone() ||
                !refEq(owned.managedJobAdmission.getOrThrow(), admission) || admission.cancellationToken.isCancelled(nowMillis: nowMillis()) ||
                owned.lifecycle.scope.token.isCancelled(nowMillis: nowMillis())) {
                return managedJobDenied("task.managed_job_owner_inactive")
            }
            let frozen = parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: 8388608)
            let snapshot = controlMetadataSnapshot()
            let envelope = ResultEnvelope(snapshot.thread.id, owned.turnId, owned.runId, owned.epoch, snapshot.nextResultSequence,
                ThreadItemDraft(itemId, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, frozen),
                    ItemProvenance("direct_tool", runId: Some(owned.runId), operationId: Some(operationId),
                        directOrigin: Some(DirectCallOrigin.ManagedJob(admission.binding))), createdAtMillis: createdAtMillis))
            match (coordinator.commitExternalCall(envelope)) {
                case SemanticCommitDecision.Committed(item, _) =>
                    owned.managedJobCallCommitted = true
                    Result.Ok(DirectToolCallRef(item, operationId, owned.runId, owned.epoch, ToolCall(call.callId, call.name, frozen),
                        managedJobGuard: Some(admission)))
                case SemanticCommitDecision.Stale(reason) => runtimeConflict(reason.code, reason.message)
                case SemanticCommitDecision.Rejected(error) => Result.Err(error)
            }
        } finally { lock.unlock() }
    }

    // Trusted host composition only. Origin describes why this Run exists; it
    // grants no capability, approval, network access or hidden service port.
    public func startHostServiceTurn(
        turnId: SemanticTurnId, runId: RunId, initiatorItemId: ItemId,
        origin: HostServiceOrigin, lane: ModelLane, contextSnapshot: InvocationContextProjection,
        createdAtMillis!: Int64 = 0, deadlineMillis!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None,
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main")
    ): Result<HostServiceRunAdmission> {
        let started = match (startTurnOwned(turnId, runId, initiatorItemId,
            ThreadItemContent.SystemNote("Host service " + hostServiceActionName(origin.action) + ": " + origin.serviceId),
            lane, contextSnapshot, createdAtMillis: createdAtMillis, deadlineMillis: deadlineMillis,
            parentCancellation: parentCancellation, runBudgetSnapshot: runBudgetSnapshot,
            executionLaneId: executionLaneId, hostServiceOrigin: Some(origin))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        lock.lock()
        try {
            match (active) {
                case Some(value) =>
                    if (settling || !value.directAttestationAllowed || value.runId.value != started.runId.value ||
                        value.epoch != started.epoch) {
                        return runtimeConflict("runtime.run_stale", "host service Run changed before admission")
                    }
                    Result.Ok(HostServiceRunAdmission(started, origin, hostOriginSeal))
                case None => runtimeConflict("runtime.no_active_run", "host service Run is no longer active")
            }
        } finally { lock.unlock() }
    }

    public func commitHostServiceToolCall(
        admission: HostServiceRunAdmission, itemId: ItemId, operationId: OperationId,
        call: ToolCall, expectedRunId: RunId, expectedEpoch: Int64,
        createdAtMillis!: Int64 = 0
    ): Result<DirectToolCallRef> {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict("runtime.no_active_run", "host service ToolCall requires an active Run")
            }
            let origin = match (owned.hostServiceOrigin) {
                case Some(value) => value
                case None => return runtimeConflict("operation.host_origin_required", "user Run cannot claim host service origin")
            }
            let (state, _) = owned.lifecycle.machine.snapshot()
            let snapshot = controlMetadataSnapshot()
            if (!refEq(admission.seal, hostOriginSeal) || settling || !owned.directAttestationAllowed ||
                state != RunState.Running || owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch ||
                admission.run.threadId.value != snapshot.thread.id.value || admission.run.turnId.value != owned.turnId.value ||
                admission.run.runId.value != owned.runId.value || admission.run.epoch != owned.epoch ||
                !sameDirectCallOrigin(DirectCallOrigin.HostService(origin), DirectCallOrigin.HostService(admission.origin))) {
                return runtimeConflict("operation.host_origin_stale", "host service admission does not own this live Run and epoch")
            }
            let arguments: AgentValue
            let envelope: ResultEnvelope
            try {
                arguments = parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: 65536)
                envelope = ResultEnvelope(snapshot.thread.id, owned.turnId, owned.runId, owned.epoch,
                    snapshot.nextResultSequence, ThreadItemDraft(itemId,
                        ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, arguments),
                        ItemProvenance("direct_tool", runId: Some(owned.runId), operationId: Some(operationId),
                            directOrigin: Some(DirectCallOrigin.HostService(origin))), createdAtMillis: createdAtMillis))
            } catch (_: Exception) {
                return Result.Err(AgentError(AgentErrorKind.InvalidInput, "operation.host_input_invalid",
                    "host service call requires valid identity and JSON input within 64 KiB"))
            }
            match (coordinator.commitHostServiceCall(envelope)) {
                case SemanticCommitDecision.Committed(item, _) => Result.Ok(DirectToolCallRef(item, operationId,
                    owned.runId, owned.epoch, ToolCall(call.callId, call.name, arguments)))
                case SemanticCommitDecision.Stale(reason) => runtimeConflict(reason.code, reason.message)
                case SemanticCommitDecision.Rejected(error) => Result.Err(error)
            }
        } finally { lock.unlock() }
    }

    // Only the host ingress owner holds connection. Typed origin is persisted
    // evidence; it cannot be supplied to this entry in place of the seal.
    public func startExternalTurn(
        connection: ExternalIngressConnection, request: ExternalRequestId, call: ToolCall,
        turnId: SemanticTurnId, runId: RunId, initiatorItemId: ItemId,
        lane: ModelLane, contextSnapshot: InvocationContextProjection,
        createdAtMillis!: Int64 = 0, deadlineMillis!: Int64 = 0,
        runBudgetSnapshot!: AgentValue = objectValue([]), executionLaneId!: LaneId = LaneId("main"),
        receivedFrame!: ?ExternalReceivedFrame = None
    ): Result<ExternalCallAdmission> {
        try { let _ = contextSnapshotValue(contextSnapshot) } catch (_: Exception) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "context.snapshot_invalid",
                "External Run context exceeds the supported immutable snapshot envelope"))
        }
        let guard = match (connection.reserve(controlMetadataSnapshot().thread.id, request, call, frame: receivedFrame)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let deadline = if (deadlineMillis <= 0 || deadlineMillis > guard.origin.expiresAtMillis) {
            guard.origin.expiresAtMillis
        } else { deadlineMillis }
        let started = match (startTurnOwned(turnId, runId, initiatorItemId,
            ThreadItemContent.SystemNote("External request: " + call.name), lane, contextSnapshot,
            createdAtMillis: createdAtMillis, deadlineMillis: deadline,
            parentCancellation: Some(guard.requestSource.token), runBudgetSnapshot: runBudgetSnapshot,
            executionLaneId: executionLaneId, externalOrigin: Some(guard.origin), externalGuard: Some(guard))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        lock.lock()
        try {
            let owned = active.getOrThrow()
            if (settling || owned.runId.value != started.runId.value || owned.epoch != started.epoch ||
                owned.externalGuard.isNone() || !refEq(owned.externalGuard.getOrThrow(), guard)) {
                return runtimeConflict("external.owner_changed", "external request lost its live Thread owner")
            }
            guard.bindOwner({ => validateExternalOwner(guard, started.runId, started.epoch) }, owned.lifecycle.scope.childToken())
            Result.Ok(ExternalCallAdmission(started, guard, externalOriginSeal))
        } finally { lock.unlock() }
    }

    private func validateExternalOwner(guard: ExternalRequestGuard, runId: RunId, epoch: Int64): Result<Unit> {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return externalDenied("external.owner_inactive")
            }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || !owned.directAttestationAllowed || state != RunState.Running ||
                owned.runId.value != runId.value || owned.epoch != epoch || owned.externalGuard.isNone() ||
                !refEq(owned.externalGuard.getOrThrow(), guard) || guard.token().isCancelled()) {
                return externalDenied("external.owner_inactive")
            }
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func commitExternalToolCall(admission: ExternalCallAdmission, itemId: ItemId,
        operationId: OperationId, call: ToolCall, expectedRunId: RunId, expectedEpoch: Int64,
        createdAtMillis!: Int64 = 0): Result<DirectToolCallRef> {
        // Authorization callbacks run outside the Thread lock. After this
        // check the cancellation token and exact owner are checked under lock.
        match (admission.validateLive()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return externalDenied("external.owner_inactive")
            }
            let (state, _) = owned.lifecycle.machine.snapshot()
            let snapshot = controlMetadataSnapshot()
            if (!refEq(admission.seal, externalOriginSeal) || settling || !owned.directAttestationAllowed ||
                owned.externalGuard.isNone() || !refEq(owned.externalGuard.getOrThrow(), admission.guard) ||
                state != RunState.Running || owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch ||
                admission.run.threadId.value != snapshot.thread.id.value || admission.run.turnId.value != owned.turnId.value ||
                admission.run.runId.value != owned.runId.value || admission.run.epoch != owned.epoch ||
                admission.cancellationToken.isCancelled() || !admission.matchesInput(call)) {
                return externalDenied("external.admission_stale")
            }
            let frozen = admission.guard.call()
            let envelope = ResultEnvelope(snapshot.thread.id, owned.turnId, owned.runId, owned.epoch,
                snapshot.nextResultSequence, ThreadItemDraft(itemId,
                    ThreadItemContent.ToolCall(CanonicalToolCallId(frozen.callId), frozen.name, frozen.arguments),
                    ItemProvenance("direct_tool", runId: Some(owned.runId), operationId: Some(operationId),
                        directOrigin: Some(DirectCallOrigin.External(admission.origin))), createdAtMillis: createdAtMillis))
            match (coordinator.commitExternalCall(envelope)) {
                case SemanticCommitDecision.Committed(item, _) => Result.Ok(DirectToolCallRef(item, operationId,
                    owned.runId, owned.epoch, frozen, externalGuard: Some(admission.guard)))
                case SemanticCommitDecision.Stale(reason) => runtimeConflict(reason.code, reason.message)
                case SemanticCommitDecision.Rejected(error) => Result.Err(error)
            }
        } finally { lock.unlock() }
    }

    // This entry belongs to the existing live Run. It creates no Turn, budget,
    // model Attempt or Operation. A policy-approved exact plan must follow.
    public func beginContextRead(call: ToolCall, ownerNamespace: String, packageDigest: String,
        configurationDigest: String, requestId: String, expectedRunId: RunId, expectedEpoch: Int64,
        expectedProjectionDigest: String, parent!: ?OperationRootSource = None): Result<ContextReadAdmission> {
        match (parent) { case Some(OperationRootSource.Direct(value)) =>
            match (value.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (value.origin) { case DirectCallOrigin.UserDirect => (); case _ => return contextReadDenied("context.read_parent_origin_unsupported") }
            if (value.runId.value != expectedRunId.value || value.epoch != expectedEpoch) { return contextReadDenied("context.read_parent_changed") }
            case _ => () }
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return contextReadDenied("context.read_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            let snapshot = controlMetadataSnapshot()
            let parentItem = match (parent) { case Some(value) => value.itemId().value; case None => "" }
            let parentDecision = match (parent) { case Some(OperationRootSource.Committed(value)) => value.decisionId.value; case _ => "" }
            let parentScoped = match (parent) { case Some(OperationRootSource.Committed(value)) => value.scopedToolCallId.value; case _ => "" }
            let parentKind = match (parent) { case Some(OperationRootSource.Committed(_)) => "committed"; case Some(OperationRootSource.Direct(_)) => "direct"; case None => "" }
            let parentOperation = match (parent) { case Some(OperationRootSource.Direct(value)) => value.operationId.value; case _ => "" }
            if (settling || !owned.directAttestationAllowed || owned.hostServiceOrigin.isSome() || owned.externalOrigin.isSome() || owned.managedJobOrigin.isSome() ||
                owned.lifecycle.scope.token.isCancelled() || state != RunState.Running ||
                owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch ||
                contextReadProjectionDigest(owned.contextSnapshot) != expectedProjectionDigest ||
                owned.contextReadRequests.size >= 4096 || owned.contextReadRequests.contains(requestId) ||
                call.name != HOST_CONTEXT_READ_TOOL || call.callId.trimAscii() == "") {
                return contextReadDenied("context.read_owner_inactive")
            }
            match (coordinator.validateContextReadParent(parent)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            try {
                let _ = ContextReadOrigin(ownerNamespace, packageDigest, configurationDigest,
                    expectedProjectionDigest, "0000000000000000000000000000000000000000000000000000000000000000", requestId, parentItem,
                    parentDecisionId: parentDecision, parentScopedCallId: parentScoped, parentKind: parentKind, parentOperationId: parentOperation)
                let encoded = stringifyUnifiedJson(call.arguments)
                let frozen = ToolCall(call.callId, call.name, parseUnifiedJson(encoded, maxBytes: 65536))
                let admission = ContextReadAdmission(activeIdentitySnapshot159(owned), ownerNamespace, packageDigest,
                    configurationDigest, requestId, parentItem, parentDecision, parentScoped, parentKind, parentOperation, frozen, contextReadSeal,
                    { => validateContextReadOwner(expectedRunId, expectedEpoch, expectedProjectionDigest, requestId) })
                owned.contextReadRequests.add(requestId)
                Result.Ok(admission)
            } catch (_: Exception) { contextReadDenied("context.read_input_invalid") }
        } finally { lock.unlock() }
    }

    private func validateContextReadOwner(run: RunId, epoch: Int64, projection: String, request: String): Result<Unit> {
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return contextReadDenied("context.read_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || !owned.directAttestationAllowed ||
                (state != RunState.Running && state != RunState.WaitingApproval) ||
                owned.lifecycle.scope.token.isCancelled() || owned.runId.value != run.value || owned.epoch != epoch ||
                !owned.contextReadRequests.contains(request) || contextReadProjectionDigest(owned.contextSnapshot) != projection) {
                return contextReadDenied("context.read_owner_inactive")
            }
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func commitContextReadToolCall(admission: ContextReadAdmission, itemId: ItemId,
        operationId: OperationId, canonicalCall: ToolCall, plan: NormalizedOperationPlan,
        createdAtMillis!: Int64 = 0): Result<DirectToolCallRef> {
        match (admission.validateLive()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return contextReadDenied("context.read_owner_inactive") }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (!refEq(admission.seal, contextReadSeal) || settling || !owned.directAttestationAllowed ||
                state != RunState.Running || owned.lifecycle.scope.token.isCancelled() ||
                owned.runId.value != admission.run.runId.value || owned.epoch != admission.run.epoch ||
                owned.contextReadCommitted.contains(admission.requestId) || !isContextReadPlan(plan) ||
                !admission.matchesCallIdentity(canonicalCall) || plan.toolName != canonicalCall.name ||
                canonicalAgentValue(canonicalCall.arguments) != canonicalAgentValue(plan.canonicalArguments) ||
                contextReadProjectionDigest(owned.contextSnapshot) != contextReadProjectionDigest(admission.run.contextSnapshot)) {
                return contextReadDenied("context.read_plan_changed")
            }
            let snapshot = controlMetadataSnapshot()
            try {
                let call = ToolCall(canonicalCall.callId, canonicalCall.name,
                    parseUnifiedJson(stringifyUnifiedJson(canonicalCall.arguments), maxBytes: 65536))
                let guard = ContextReadGuard(admission, plan, call)
                let envelope = ResultEnvelope(snapshot.thread.id, owned.turnId, owned.runId, owned.epoch,
                    snapshot.nextResultSequence, ThreadItemDraft(itemId,
                        ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                        ItemProvenance("direct_tool", runId: Some(owned.runId), operationId: Some(operationId),
                            directOrigin: Some(DirectCallOrigin.ContextRead(guard.origin))), createdAtMillis: createdAtMillis))
                match (coordinator.commitContextReadCall(envelope)) {
                    case SemanticCommitDecision.Committed(item, _) =>
                        owned.contextReadCommitted.add(admission.requestId)
                        Result.Ok(DirectToolCallRef(item, operationId, owned.runId, owned.epoch, call,
                            contextReadGuard: Some(guard)))
                    case SemanticCommitDecision.Stale(reason) => runtimeConflict(reason.code, reason.message)
                    case SemanticCommitDecision.Rejected(error) => Result.Err(error)
                }
            } catch (_: Exception) { contextReadDenied("context.read_input_invalid") }
        } finally { lock.unlock() }
    }

    public func ownTask(name: String, future: Future<Unit>,
        expectedRunId!: ?RunId = None, expectedEpoch!: ?Int64 = None,
        blocksModelBoundary!: Bool = false): Result<Unit> {
        match (ownTaskWithJoin(name, future, expectedRunId: expectedRunId,
            expectedEpoch: expectedEpoch, blocksModelBoundary: blocksModelBoundary)) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func ownTaskWithJoin(name: String, future: Future<Unit>,
        expectedRunId!: ?RunId = None, expectedEpoch!: ?Int64 = None,
        blocksModelBoundary!: Bool = false): Result<RunTaskJoin> {
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            match (active) {
                case Some(value) =>
                    if ((expectedRunId.isSome() && expectedRunId.getOrThrow().value != value.runId.value) ||
                        (expectedEpoch.isSome() && expectedEpoch.getOrThrow() != value.epoch)) {
                        return runtimeConflict("runtime.run_stale", "Task owner identity or epoch is stale")
                    }
                    value.lifecycle.scope.ownWithJoin(name, future, blocksModelBoundary: blocksModelBoundary)
                case None => runtimeConflict("runtime.no_active_run", "Thread has no active Run")
            }
        } finally {
            lock.unlock()
        }
    }

    // Used only before the next claimed model dispatch, not during an
    // already-admitted Attempt's own resource callbacks.
    public func requireModelBoundary(expectedRunId: RunId, expectedEpoch: Int64): Result<Unit> {
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return runtimeConflict("runtime.no_active_run", "Model boundary has no active Run") }
            if (settling || owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch ||
                owned.lifecycle.scope.token.isCancelled()) {
                return runtimeConflict("runtime.run_stale", "Model boundary owner changed or was cancelled")
            }
            if (owned.lifecycle.scope.hasPendingModelBoundaryTask()) {
                return runtimeConflict("runtime.model_resources_unsettled", "Owned model resources have not acknowledged cleanup")
            }
            Result.Ok(())
        } finally { lock.unlock() }
    }

    // Cancellation-only parent linkage for a recovered/current owner. Capture
    // the actual scope once: a late callback can never target a replacement Run.
    // Register and dispose outside the Runtime lock because onCancel may invoke
    // an already-cancelled parent's callback synchronously.
    public func bindCancellationParent(expectedRunId: RunId, expectedEpoch: Int64,
        parent: CancellationToken): Result<CancellationRegistration> {
        lock.lock()
        let owned = try {
            let value = match (active) { case Some(value) => value
                case None => return runtimeConflict("runtime.no_active_run", "cancellation link requires its active owner") }
            if (settling || value.runId.value != expectedRunId.value || value.epoch != expectedEpoch) {
                return runtimeConflict("runtime.run_stale", "cancellation link owner or epoch is stale")
            }
            value
        } finally { lock.unlock() }
        let registration = parent.onCancel({ reason =>
            let _ = owned.lifecycle.scope.cancel(reason: Some(reason))
        })
        lock.lock()
        let current = try {
            !settling && match (active) {
                case Some(value) => refEq(value, owned)
                case None => false
            }
        } finally { lock.unlock() }
        if (!current) {
            registration.dispose()
            return runtimeConflict("runtime.run_stale", "cancellation link owner changed during registration")
        }
        Result.Ok(registration)
    }

    // Observes the existing scope token without allocating or retaining a new
    // child. Hot resource polls must not grow the Run's owned child list.
    // This Host-only reference has no cancellation or Run admission methods.
    public func currentRunCancellationToken(expectedRunId: RunId,
        expectedEpoch: Int64): Result<CancellationToken> {
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            match (active) {
                case Some(value) =>
                    if (expectedRunId.value != value.runId.value || expectedEpoch != value.epoch) {
                        return runtimeConflict("runtime.run_stale", "Cancellation owner identity or epoch is stale") }
                    Result.Ok(value.lifecycle.scope.token)
                case None => runtimeConflict("runtime.no_active_run", "Thread has no active Run")
            }
        } finally { lock.unlock() }
    }

    public func childCancellationToken(
        deadlineMillis!: Int64 = 0,
        expectedRunId!: ?RunId = None,
        expectedEpoch!: ?Int64 = None
    ): Result<CancellationToken> {
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            match (active) {
                case Some(value) =>
                    match (expectedRunId) {
                        case Some(expected) => if (expected.value != value.runId.value) {
                            return runtimeConflict("runtime.run_stale", "Cancellation owner identity is stale")
                        }
                        case None => ()
                    }
                    match (expectedEpoch) {
                        case Some(expected) => if (expected != value.epoch) {
                            return runtimeConflict("runtime.run_stale", "Cancellation owner epoch is stale")
                        }
                        case None => ()
                    }
                    Result.Ok(value.lifecycle.scope.childToken(deadlineMillis: deadlineMillis))
                case None => runtimeConflict(
                    "runtime.no_active_run", "Thread has no active Run"
                )
            }
        } finally {
            lock.unlock()
        }
    }

    public func commitResult(envelope: ResultEnvelope): SemanticCommitDecision {
        lock.lock()
        try {
            match (active) {
                case Some(value) =>
                    if (!matchesActive(value, envelope)) {
                        return coordinator.commit(envelope)
                    }
                    coordinator.commit(envelope)
                case None => coordinator.commit(envelope)
            }
        } finally {
            lock.unlock()
        }
    }

    public func commitBatch(envelope: ResultBatchEnvelope): SemanticBatchCommitDecision {
        lock.lock()
        try {
            coordinator.commitBatch(envelope)
        } finally {
            lock.unlock()
        }
    }

    // Converts durable-store source evidence into the only capability accepted
    // by production tool preparation. The canonical item must already exist in
    // this Thread and must still identify the exact provider-local call/name.
    public func attestCommittedToolCalls(
        sources: Array<CommittedToolCallSource>
    ): Result<Array<CommittedToolCallRef>> {
        lock.lock()
        try {
            coordinator.attestCommittedToolCalls(sources)
        } finally { lock.unlock() }
    }

    // Explicit opt-in data projection after canonical settlement. Native
    // compute runs BEFORE this loan; only its final SQL save may consume it.
    public func captureDirectPostCanonicalProjection(source: DirectToolCallRef,
        budget: ExecutionBudget): Result<DirectPostCanonicalProjectionBoundary> {
        match (source.origin) { case DirectCallOrigin.UserDirect => ()
            case _ => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "runtime.projection_direct_origin_invalid", "projection requires an actual UserDirect invocation")) }
        lock.lock()
        try {
            let owned = match (active) { case Some(value) => value
                case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "runtime.projection_owner_missing", "post-canonical projection has no active Run")) }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (settling || !owned.directAttestationAllowed || state != RunState.Running ||
                owned.runId.value != source.runId.value || owned.epoch != source.epoch ||
                owned.turnId.value != source.turnId.value || controlMetadataSnapshot().thread.id.value != source.threadId.value ||
                owned.hostServiceOrigin.isSome() || owned.externalOrigin.isSome() || owned.managedJobOrigin.isSome() ||
                owned.lifecycle.scope.token.isCancelled() || owned.contextUpdate.isSome() || budget.snapshot().activeTools != 0) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "runtime.projection_owner_changed", "post-canonical projection lost its actual Run or slot")) }
            Result.Ok(DirectPostCanonicalProjectionBoundary(source, budget, { action: () -> Result<Unit> =>
                withDirectPostCanonicalProjection(owned, source, budget, action) }))
        } finally { lock.unlock() }
    }
    private func withDirectPostCanonicalProjection(expected: OwnedActiveRun, source: DirectToolCallRef,
        budget: ExecutionBudget, action: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            let actual = match (active) { case Some(value) => value
                case None => return directPostCanonicalProjectionFailure("runtime.projection_owner_missing") }
            let (state, _) = actual.lifecycle.machine.snapshot()
            if (!refEq(expected, actual) || settling || state != RunState.Running ||
                actual.runId.value != source.runId.value || actual.epoch != source.epoch || actual.contextUpdate.isSome() ||
                actual.lifecycle.scope.token.isCancelled() || budget.snapshot().activeTools != 0) {
                return directPostCanonicalProjectionFailure("runtime.projection_owner_changed") }
            // Runtime -> original Scope -> SQL. Callback contains no Native
            // query/await/Host lock; its SQL guards are cancellation-only.
            actual.lifecycle.scope.withSettledDataProjection(action)
        } finally { lock.unlock() }
    }

    // Recovery may inspect a direct Item, but cannot revive the process that
    // owned its handoff. Only a fresh live owner can mint direct authority.
    public func attestDirectToolCall(
        itemId: ItemId,
        operationId: OperationId,
        expectedRunId: RunId,
        expectedEpoch: Int64
    ): Result<DirectToolCallRef> {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict("runtime.no_active_run", "Direct attestation requires an active Run")
            }
            if (settling || !owned.directAttestationAllowed) {
                return runtimeConflict("operation.direct_recovery_forbidden", "Direct roots cannot be minted from a settling or recovered Run")
            }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch ||
                state != RunState.Running) {
                return runtimeConflict("runtime.run_stale", "Direct attestation requires the current running epoch")
            }
            let snapshot = coordinator.snapshot()
            for (item in snapshot.items where item.id.value == itemId.value) {
                if (item.threadId.value != snapshot.thread.id.value ||
                    item.turnId.value != owned.turnId.value ||
                    item.provenance.source != "direct_tool" ||
                    item.provenance.runId.isNone() ||
                    item.provenance.runId.getOrThrow().value != owned.runId.value ||
                    item.provenance.operationId.isNone() ||
                    item.provenance.operationId.getOrThrow().value != operationId.value) {
                    break
                }
                match (item.content) {
                    case ThreadItemContent.ToolCall(callId, name, arguments) =>
                        let expectedOrigin = match (owned.hostServiceOrigin) {
                            case Some(value) => DirectCallOrigin.HostService(value)
                            case None => match (owned.externalOrigin) {
                                case Some(value) => DirectCallOrigin.External(value)
                                case None => match (owned.managedJobOrigin) {
                                    case Some(value) => DirectCallOrigin.ManagedJob(value)
                                    case None => DirectCallOrigin.UserDirect
                                }
                            }
                        }
                        if (!sameDirectCallOrigin(effectiveDirectCallOrigin(item.provenance), expectedOrigin)) { break }
                        return Result.Ok(DirectToolCallRef(item, operationId, owned.runId,
                            owned.epoch, ToolCall(callId.value, name, arguments), externalGuard: owned.externalGuard,
                                managedJobGuard: owned.managedJobAdmission))
                    case _ => break
                }
            }
            runtimeConflict("operation.direct_source_not_canonical", "Direct source is not the current canonical ToolCall and operation binding")
        } finally { lock.unlock() }
    }

    public func commitOperationResult(
        envelope: ResultEnvelope,
        receipt: VNextOperationReceipt,
        nextState!: RunState = RunState.Running
    ): SemanticCommitDecision {
        lock.lock()
        try {
            coordinator.commitOperationResult(
                envelope, receipt, runStateName(nextState)
            )
        } finally {
            lock.unlock()
        }
    }

    // Usage may arrive after cancellation. It remains attributable diagnostic
    // evidence, but unlike a late Item it can never mutate Thread semantics.
    public func recordModelUsage(sample: RunModelUsageSample): Result<Unit> {
        coordinator.recordModelUsage(sample)
    }

    public func resolveOperation(
        itemId: ItemId,
        operationId: OperationId,
        callId: CanonicalToolCallId,
        plan: NormalizedOperationPlan,
        stage: OperationAttemptStage,
        attempt: Result<ToolInvocationResult>,
        receiptId: String,
        observedAtMillis: Int64,
        expectedRunId!: ?RunId = None,
        expectedEpoch!: ?Int64 = None,
        knownParentSource!: ?OperationRootSource = None,
        knownParentGuard!: ?()->Result<Unit> = None
    ): Result<RuntimeOperationResolution> {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict(
                    "runtime.no_active_run", "Operation resolution requires an active Run"
                )
            }
            if ((expectedRunId.isSome() && expectedRunId.getOrThrow().value != owned.runId.value) ||
                (expectedEpoch.isSome() && expectedEpoch.getOrThrow() != owned.epoch)) {
                return runtimeConflict(
                    "runtime.run_stale", "Operation resolution belongs to a replaced Run"
                )
            }
            let resolution = resolveOperationAttempt(
                operationId, callId, plan, stage, attempt, receiptId, observedAtMillis
            )
            match (resolution) {
                case OperationResolution.WaitingApproval(_) =>
                    if (settling) {
                        return runtimeConflict("runtime.run_settling", "Run is settling")
                    }
                    match (transitionOwned(owned, RunState.WaitingApproval)) {
                        case Result.Ok(_) => Result.Ok(RuntimeOperationResolution(resolution))
                        case Result.Err(error) => Result.Err(error)
                    }
                case OperationResolution.Terminal(terminal) =>
                    match (terminal.toolResult) {
                        case Some(result) =>
                            let thread = controlMetadataSnapshot()
                            let (runState, _) = owned.lifecycle.machine.snapshot()
                            let known:?OwnedCanonicalParentCommit=if(!knownParentHistoryEnabled){None}else{match(knownParentSource){
                                case Some(source)=>
                                    if(stage!=OperationAttemptStage.Executing || knownParentGuard.isNone() ||
                                        result.payloadLease.isNone() || !(isPluginLivePolicyParentPlan(plan) || isManagedChannelOwnedParentPlan(plan))){
                                        return runtimeConflict("runtime.known_commit_scope_invalid","known commit lacks its actual owned source/output") }
                                    Some(OwnedCanonicalParentCommit(source,plan,operationId,owned.runId,thread.thread.id,
                                        owned.epoch,result,knownParentGuard.getOrThrow()))
                                case None=>None}}
                            let decision = coordinator.commitOperationResult(
                                ResultEnvelope(
                                    thread.thread.id, owned.turnId, owned.runId, owned.epoch,
                                    thread.nextResultSequence,
                                    ThreadItemDraft(
                                        itemId,
                                        ThreadItemContent.ToolResult(
                                            CanonicalToolCallId(result.callId),
                                            terminal.receipt.operationId,
                                            terminal.receipt.receiptId,
                                            result.output,
                                            result.isError
                                        ),
                                        ItemProvenance(
                                            "operation", runId: Some(owned.runId),
                                            operationId: Some(terminal.receipt.operationId)
                                        ),
                                        createdAtMillis: observedAtMillis
                                    )
                                ),
                                terminal.receipt,
                                runStateName(runState),
                                ownedCanonicalParent:known
                            )
                            match (decision) {
                                case SemanticCommitDecision.Committed(_, _) => ()
                                case _ => if(known.isSome()){
                                    // An opt-in proof failure rolled back the same canonical TX.
                                    // Do not write a detached receipt in a second transaction.
                                    ()
                                }else{match (coordinator.recordOperationReceipt(
                                    owned.runId, terminal.receipt
                                )) {
                                    case Result.Ok(_) => ()
                                    case Result.Err(error) => return Result.Err(error)
                                }}
                            }
                            Result.Ok(RuntimeOperationResolution(
                                resolution, semanticCommit: Some(decision)
                            ))
                        case None =>
                            match (coordinator.recordOperationReceipt(
                                owned.runId, terminal.receipt
                            )) {
                                case Result.Ok(_) => Result.Ok(RuntimeOperationResolution(resolution))
                                case Result.Err(error) => Result.Err(error)
                            }
                    }
            }
        } finally {
            lock.unlock()
        }
    }

    public func resumeAfterApproval(): Result<RunTransition> {
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            match (active) {
                case Some(value) => transitionOwned(value, RunState.Running)
                case None => runtimeConflict(
                    "runtime.no_active_run", "Thread has no approval-paused Run"
                )
            }
        } finally {
            lock.unlock()
        }
    }

    public func pauseForApproval(): Result<RunTransition> {
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            match (active) {
                case Some(value) => transitionOwned(value, RunState.WaitingApproval)
                case None => runtimeConflict(
                    "runtime.no_active_run", "Thread has no Run to pause for approval"
                )
            }
        } finally {
            lock.unlock()
        }
    }

    public func projectContext(
        checkpoint!: ?ContextCheckpoint = None,
        dynamicState!: AgentValue = objectValue([])
    ): Result<ModelContextProjection> {
        lock.lock()
        try {
            match (active) {
                case Some(value) => if ((value.hostServiceOrigin.isSome() || value.externalOrigin.isSome() || value.managedJobOrigin.isSome())) {
                    return runtimeConflict("runtime.host_service_has_no_model", "maintenance Runs cannot project a model request")
                }
                case None => ()
            }
            match (active) {
                case Some(value) =>
                    let thread = coordinator.snapshot()
                    // A checkpoint saved by this Run's own rewind call covers
                    // that call's ToolResult and, therefore, also this Turn's
                    // initiator Item. Projecting it would hide the Turn intent
                    // that the current model request must still name, so the
                    // active Turn's own coverage is excluded here. Completed
                    // Turns are unaffected: their initiator is already behind
                    // the checkpoint, which is the intended rewind behavior.
                    let selected: ?ContextCheckpoint = match (checkpoint) {
                        case Some(explicit) => Some(explicit)
                        case None => match (checkpointRepository) {
                            case Some(repository) =>
                                value.lane.markHistoricalLaneExport159()
                                var initiatorItem = ""
                                for (turn in thread.turns) {
                                    if (turn.id.value == value.turnId.value) { initiatorItem = turn.initiatorItemId.value }
                                }
                                var initiatorOrdinal: Int64 = 0
                                for (item in thread.items) {
                                    if (item.id.value == initiatorItem) { initiatorOrdinal = item.ordinal }
                                }
                                let latest = repository.loadLatest(thread, projector.version, value.lane.protocol)
                                match (latest) {
                                    case Some(candidate) =>
                                        if (initiatorOrdinal > 0 && candidate.coversThroughItemOrdinal >= initiatorOrdinal) {
                                            None
                                        } else {
                                            Some(candidate)
                                        }
                                    case None => None
                                }
                            case None => None
                        }
                    }
                    projector.project(
                        thread, value.lane,
                        checkpoint: selected, dynamicState: dynamicState
                    )
                case None => runtimeConflict(
                    "runtime.no_active_run", "Context projection requires an active Run"
                )
            }
        } finally {
            lock.unlock()
        }
    }

    // Split only the existing cancellation transition from its later join.
    // A token signal alone has not yet changed the durable Run state. Pending
    // canonical read/call receipts must settle in Cancelling before final join.
    public func beginCancellationSettlement(expectedRunId: RunId, expectedEpoch: Int64): Result<Unit> {
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is already joining owned work") }
            let owned = match (active) { case Some(value) => value
                case None => return runtimeConflict("runtime.no_active_run", "cancellation settlement requires its active owner") }
            if (owned.runId.value != expectedRunId.value || owned.epoch != expectedEpoch) {
                return runtimeConflict("runtime.run_stale", "cancellation settlement owner or epoch is stale")
            }
            if (!owned.lifecycle.scope.token.isCancelled(nowMillis: nowMillis())) {
                return runtimeConflict("runtime.cancellation_not_requested", "actual Run token has not been cancelled")
            }
            let (state, _) = owned.lifecycle.machine.snapshot()
            if (state == RunState.Cancelling) { return Result.Ok(()) }
            if (state != RunState.WaitingApproval && state != RunState.Running) {
                return runtimeConflict("runtime.cancellation_settlement_phase", "early settlement requires a cancelled running or approval-paused owner")
            }
            match (transitionOwned(owned, RunState.Cancelling, reason: "cancel_requested")) {
                case Result.Ok(_) => Result.Ok(()); case Result.Err(error) => Result.Err(error)
            }
        } finally { lock.unlock() }
    }

    public func cancel(
        joinTimeoutMillis: Int64,
        reason!: ?CancellationReason = None,
        expectedRunId!: ?RunId = None,
        expectedEpoch!: ?Int64 = None
    ): Result<RuntimeSettlement> {
        if (joinTimeoutMillis < 0) {
            throw IllegalArgumentException("run join timeout must not be negative")
        }
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict(
                    "runtime.no_active_run", "Thread has no active Run to cancel"
                )
            }
            if ((expectedRunId.isSome() && expectedRunId.getOrThrow().value != owned.runId.value) ||
                (expectedEpoch.isSome() && expectedEpoch.getOrThrow() != owned.epoch)) {
                return runtimeConflict("runtime.run_stale", "Run cancellation identity or epoch is stale")
            }
            // No new payment refusal may first appear after durable terminal
            // commit. A failed join/commit retains this same private reserve.
            owned.reserveOutwardView159()
            let (beforeCancellation, _) = owned.lifecycle.machine.snapshot()
            if (beforeCancellation != RunState.Cancelling) {
                match (transitionOwned(owned, RunState.Cancelling, reason: "cancel_requested")) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
            }
            settling = true
            lock.unlock()
            let report = try {
                let _ = owned.lifecycle.scope.cancel(reason: reason)
                owned.lifecycle.joinOwned(joinTimeoutMillis)
            } catch (error: Exception) {
                lock.lock()
                try {
                    markSettlementRecovery(owned, "owned_settlement_exception")
                } finally { lock.unlock() }
                return runtimeConflict("runtime.owned_settlement_failed", error.message)
            } finally { lock.lock() }
            let effective = effectiveRunTerminal(RunState.Cancelled, report)
            let finishedAtMillis = nowMillis()
            let cancellationText = match (reason) {
                case Some(value) => value.code + ": " + value.message
                case None => "cancel_requested"
            }
            let terminalProposal = owned.lifecycle.machine.preview(
                effective, reason: if (effective == RunState.RecoveryRequired) {
                    "cancel_quarantined=" + report.quarantinedCount().toString()
                } else {
                    cancellationText
                }
            )
                .value().getOrThrow()
            let threadResult = if (effective == RunState.RecoveryRequired) {
                coordinator.requireRecoveryTurn(
                    owned.turnId, owned.runId, owned.epoch,
                    finishedAtMillis: Some(finishedAtMillis)
                )
            } else {
                coordinator.cancelRun(
                    owned.runId,
                    finishedAtMillis: Some(finishedAtMillis),
                    cancellationReason: Some(cancellationText)
                )
            }
            let thread = match (threadResult) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    markSettlementRecovery(owned, "durable_cancel_failed")
                    return Result.Err(error)
            }
            let _ = owned.lifecycle.machine.commitPreview(terminalProposal).value().getOrThrow()
            let _ = coordinator.recordRunTransition(
                owned.turnId, owned.runId, owned.epoch, terminalProposal, finishedAtMillis
            )
            let run = reservedActiveSnapshot159(owned)
            match (owned.contextUpdate) { case Some(update) => update.cancel(); case None => () }
            owned.contextUpdate = None
            active = None
            settling = false
            // activeSnapshot constructed an independent paid lane above. The
            // detached private owner contains no escaped reference to its lane.
            owned.returnLaneRoot159()
            Result.Ok(RuntimeSettlement(thread, run, report, returnWitness113: Some(owned.lifecycle.scope)))
        } finally {
            lock.unlock()
        }
    }

    public func finish(
        terminal: RunState,
        joinTimeoutMillis: Int64,
        reason!: String = "",
        expectedRunId!: ?RunId = None,
        expectedEpoch!: ?Int64 = None
    ): Result<RuntimeSettlement> {
        if (terminal != RunState.Completed && terminal != RunState.Failed &&
            terminal != RunState.RecoveryRequired) {
            return runtimeConflict(
                "runtime.invalid_terminal", "Run may finish only as completed, failed, or recovery-required"
            )
        }
        if (joinTimeoutMillis < 0) {
            throw IllegalArgumentException("run join timeout must not be negative")
        }
        lock.lock()
        try {
            if (settling) { return runtimeConflict("runtime.run_settling", "Run is settling") }
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict(
                    "runtime.no_active_run", "Thread has no active Run to finish"
                )
            }
            // Delayed completion from an old executor must not settle a newer
            // Run after cancellation released the Thread for fresh admission.
            match (expectedRunId) {
                case Some(value) => if (value.value != owned.runId.value) {
                    return runtimeConflict("runtime.run_stale", "Run settlement identity is stale")
                }
                case None => ()
            }
            match (expectedEpoch) {
                case Some(value) => if (value != owned.epoch) {
                    return runtimeConflict("runtime.run_stale", "Run settlement epoch is stale")
                }
                case None => ()
            }
            owned.reserveOutwardView159()
            settling = true
            lock.unlock()
            let report = try {
                owned.lifecycle.joinOwned(joinTimeoutMillis)
            } catch (error: Exception) {
                lock.lock()
                try {
                    markSettlementRecovery(owned, "owned_settlement_exception")
                } finally { lock.unlock() }
                return runtimeConflict("runtime.owned_settlement_failed", error.message)
            } finally { lock.lock() }
            let effective = effectiveRunTerminal(terminal, report)
            let settlementReason = if (reason != "") {
                reason
            } else if (report.quarantinedCount() > 0) {
                "quarantined=" + report.quarantinedCount().toString()
            } else if (report.failedCount() > 0) {
                "owned_failures=" + report.failedCount().toString()
            } else {
                "joined"
            }
            let finishedAtMillis = nowMillis()
            let terminalProposal = owned.lifecycle.machine.preview(
                effective, reason: settlementReason
            )
                .value().getOrThrow()
            let threadResult = match (effective) {
                case RunState.Completed => coordinator.completeTurn(
                    owned.turnId, owned.runId, owned.epoch,
                    finishedAtMillis: Some(finishedAtMillis)
                )
                case RunState.RecoveryRequired => coordinator.requireRecoveryTurn(
                    owned.turnId, owned.runId, owned.epoch,
                    finishedAtMillis: Some(finishedAtMillis)
                )
                case _ => coordinator.failTurn(
                    owned.turnId, owned.runId, owned.epoch,
                    finishedAtMillis: Some(finishedAtMillis)
                )
            }
            let thread = match (threadResult) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    markSettlementRecovery(owned, "durable_settlement_failed")
                    return Result.Err(error)
            }
            let _ = owned.lifecycle.machine.commitPreview(terminalProposal).value().getOrThrow()
            let _ = coordinator.recordRunTransition(
                owned.turnId, owned.runId, owned.epoch, terminalProposal, finishedAtMillis
            )
            let run = reservedActiveSnapshot159(owned)
            match (owned.contextUpdate) { case Some(update) => update.cancel(); case None => () }
            owned.contextUpdate = None
            active = None
            settling = false
            // activeSnapshot constructed an independent paid lane above. The
            // detached private owner contains no escaped reference to its lane.
            owned.returnLaneRoot159()
            Result.Ok(RuntimeSettlement(thread, run, report, returnWitness113: Some(owned.lifecycle.scope)))
        } finally {
            lock.unlock()
        }
    }

    private func markSettlementRecovery(owned: OwnedActiveRun, reason: String): Unit {
        match (transitionOwned(owned, RunState.RecoveryRequired, reason: reason)) {
            case Result.Ok(_) => ()
            case Result.Err(_) =>
                // Storage failure cannot leave the live owner claiming Running
                // after its task scope has already stopped accepting work.
                let _ = owned.lifecycle.machine.transition(RunState.RecoveryRequired, reason: reason)
        }
    }

    private func reservedActiveSnapshot159(value: OwnedActiveRun): ActiveRunSnapshot {
        let (state, sequence) = value.lifecycle.machine.snapshot()
        let owned = OwnedActiveRunFrame159(ActiveRunSnapshot(controlMetadataSnapshot().thread.id,
            value.turnId, value.runId, value.epoch, value.reservedOutwardView159(), value.contextSnapshot,
            state, sequence, executionLaneId: value.executionLaneId))
        // Keep the concrete reserve field until the complete paid carrier was
        // successfully registered; the surviving view now holds that lane.
        value.clearReservedOutwardView159()
        owned.snapshot159()
    }
    private func activeIdentitySnapshot159(value: OwnedActiveRun): ActiveRunIdentitySnapshot159 {
        let (state, sequence) = value.lifecycle.machine.snapshot()
        ActiveRunIdentitySnapshot159(controlMetadataSnapshot().thread.id,
            value.turnId, value.runId, value.epoch, value.contextSnapshot,
            state, sequence, value.executionLaneId)
    }

    private func activeSnapshot(value: OwnedActiveRun): ActiveRunSnapshot {
        activeOwnedSnapshot159(value).snapshot159()
    }
    private func activeOwnedSnapshot159(value: OwnedActiveRun): OwnedActiveRunFrame159 {
        let lane = match (value.lane.forkOwnedLaneFrame159()) {
            case Some(owned) => owned; case None => value.lane }
        let (state, sequence) = value.lifecycle.machine.snapshot()
        OwnedActiveRunFrame159(ActiveRunSnapshot(controlMetadataSnapshot().thread.id,
            value.turnId, value.runId, value.epoch, lane, value.contextSnapshot,
            state, sequence, executionLaneId: value.executionLaneId))
    }

    private func transitionOwned(
        owned: OwnedActiveRun,
        to: RunState,
        reason!: String = ""
    ): Result<RunTransition> {
        let proposal = match (owned.lifecycle.machine.preview(to, reason: reason)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (coordinator.recordRunTransition(
            owned.turnId, owned.runId, owned.epoch, proposal, nowMillis()
        )) {
            case Result.Ok(_) => owned.lifecycle.machine.commitPreview(proposal)
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func exactExternalText(item: ThreadItem, expected: String, source: String): Bool {
    if (item.provenance.source != source) { return false }
    match (item.content) {
        case ThreadItemContent.UserMessage(parts) =>
            if (parts.size != 1) { return false }
            match (parts[0]) {
                case ThreadMessagePart.Text(value) => value == expected
                case _ => false
            }
        case _ => false
    }
}

func matchesActive(active: OwnedActiveRun, envelope: ResultEnvelope): Bool {
    active.turnId.value == envelope.turnId.value &&
        active.runId.value == envelope.runId.value && active.epoch == envelope.epoch
}

func runtimeConflict<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, message))
}
