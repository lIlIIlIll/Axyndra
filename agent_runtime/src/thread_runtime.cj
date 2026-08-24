package agent_runtime

import std.sync.*
import agent_domain.*
import agent_skills.*

public class ActiveRunSnapshot {
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let lane: ModelLane
    public let skills: SkillStackSnapshot
    public let state: RunState
    public let transitionSequence: Int64

    public init(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        lane: ModelLane,
        skills: SkillStackSnapshot,
        state: RunState,
        transitionSequence: Int64
    ) {
        this.threadId = threadId
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.lane = lane
        this.skills = skills
        this.state = state
        this.transitionSequence = transitionSequence
    }
}

public class RuntimeSettlement {
    public let thread: AgentThreadSnapshot
    public let run: ActiveRunSnapshot
    public let joined: RunJoinReport

    public init(thread: AgentThreadSnapshot, run: ActiveRunSnapshot, joined: RunJoinReport) {
        this.thread = thread
        this.run = run
        this.joined = joined
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
    let turnId: SemanticTurnId
    let runId: RunId
    let epoch: Int64
    let lane: ModelLane
    let skills: SkillStackSnapshot
    let lifecycle: RunLifecycle

    init(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        lane: ModelLane,
        skills: SkillStackSnapshot,
        lifecycle: RunLifecycle
    ) {
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.lane = lane
        this.skills = skills
        this.lifecycle = lifecycle
    }
}

public class RecoveredRunSpec {
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let state: RunState
    public let transitionSequence: Int64
    public let lane: ModelLane
    public let skills: SkillStackSnapshot
    public let deadlineMillis: Int64
    public let parentCancellation: ?CancellationToken

    public init(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        state: RunState,
        transitionSequence: Int64,
        lane: ModelLane,
        skills: SkillStackSnapshot,
        deadlineMillis!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None
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
        this.skills = skills
        this.deadlineMillis = deadlineMillis
        this.parentCancellation = parentCancellation
    }
}

// AgentThreadRuntime is the only public mutable owner of a live Thread. The
// coordinator owns semantic commits; the RunLifecycle owns all async work;
// immutable ModelLane and Skill snapshots cannot drift during a Run.
public class AgentThreadRuntime {
    private let lock = Mutex()
    private let coordinator: ThreadCoordinator
    private let projector: ContextProjector
    private let checkpointRepository: ?ContextCheckpointRepository
    private let nowMillis: () -> Int64
    private var active: ?OwnedActiveRun = None

    public init(
        coordinator: ThreadCoordinator,
        projector: ContextProjector,
        nowMillis: () -> Int64,
        checkpointRepository!: ?ContextCheckpointRepository = None
    ) {
        if (coordinator.snapshot().thread.activeTurnId.isSome()) {
            throw IllegalArgumentException(
                "recovered active Thread requires explicit reconciliation before Runtime start"
            )
        }
        this.coordinator = coordinator
        this.projector = projector
        this.checkpointRepository = checkpointRepository
        this.nowMillis = nowMillis
    }

    // This constructor is intentionally separate: only a recovery coordinator
    // that has reconciled durable Operations should create a live owner.
    public init(
        coordinator: ThreadCoordinator,
        projector: ContextProjector,
        recovered: RecoveredRunSpec,
        nowMillis: () -> Int64,
        checkpointRepository!: ?ContextCheckpointRepository = None
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
        this.nowMillis = nowMillis
        this.active = Some(OwnedActiveRun(
            recovered.turnId, recovered.runId, recovered.epoch,
            recovered.lane, recovered.skills,
            RunLifecycle(
                deadlineMillis: recovered.deadlineMillis,
                parent: recovered.parentCancellation,
                initialState: recovered.state,
                transitionSequence: recovered.transitionSequence
            )
        ))
    }

    public func threadSnapshot(): AgentThreadSnapshot { coordinator.snapshot() }

    public func appendUserInput(
        itemId: ItemId,
        content: ThreadItemContent,
        provenance: ItemProvenance,
        createdAtMillis: Int64
    ): Result<ThreadItem> {
        lock.lock()
        try {
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

    public func startTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        userItemId: ItemId,
        userContent: ThreadItemContent,
        lane: ModelLane,
        skills: SkillStackSnapshot,
        createdAtMillis!: Int64 = 0,
        deadlineMillis!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None,
        runBudgetSnapshot!: AgentValue = objectValue([])
    ): Result<ActiveRunSnapshot> {
        lock.lock()
        try {
            if (active.isSome()) {
                return runtimeConflict("runtime.run_already_active", "Thread already has an active Run")
            }
            let lifecycle = RunLifecycle(deadlineMillis: deadlineMillis, parent: parentCancellation)
            let thread = match (coordinator.startTurn(
                turnId, runId, userItemId, userContent,
                createdAtMillis: createdAtMillis,
                runLaneSnapshot: modelLaneSnapshotValue(lane),
                runSkillSnapshot: skillStackSnapshotValue(skills),
                runBudgetSnapshot: runBudgetSnapshot
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
                turnId, runId, thread.activeEpoch, lane, skills, lifecycle
            )
            active = Some(owned)
            Result.Ok(activeSnapshot(owned))
        } finally {
            lock.unlock()
        }
    }

    public func ownTask(name: String, future: Future<Unit>): Result<Unit> {
        lock.lock()
        try {
            match (active) {
                case Some(value) => value.lifecycle.scope.own(name, future)
                case None => runtimeConflict("runtime.no_active_run", "Thread has no active Run")
            }
        } finally {
            lock.unlock()
        }
    }

    public func childCancellationToken(deadlineMillis!: Int64 = 0): Result<CancellationToken> {
        lock.lock()
        try {
            match (active) {
                case Some(value) => Result.Ok(
                    value.lifecycle.scope.childToken(deadlineMillis: deadlineMillis)
                )
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
        observedAtMillis: Int64
    ): Result<RuntimeOperationResolution> {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict(
                    "runtime.no_active_run", "Operation resolution requires an active Run"
                )
            }
            let resolution = resolveOperationAttempt(
                operationId, callId, plan, stage, attempt, receiptId, observedAtMillis
            )
            match (resolution) {
                case OperationResolution.WaitingApproval(_) =>
                    match (transitionOwned(owned, RunState.WaitingApproval)) {
                        case Result.Ok(_) => Result.Ok(RuntimeOperationResolution(resolution))
                        case Result.Err(error) => Result.Err(error)
                    }
                case OperationResolution.Terminal(terminal) =>
                    match (terminal.toolResult) {
                        case Some(result) =>
                            let thread = coordinator.snapshot()
                            let (runState, _) = owned.lifecycle.machine.snapshot()
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
                                runStateName(runState)
                            )
                            match (decision) {
                                case SemanticCommitDecision.Committed(_, _) => ()
                                case _ => match (coordinator.recordOperationReceipt(
                                    owned.runId, terminal.receipt
                                )) {
                                    case Result.Ok(_) => ()
                                    case Result.Err(error) => return Result.Err(error)
                                }
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
                case Some(value) =>
                    let thread = coordinator.snapshot()
                    let selected: ?ContextCheckpoint = match (checkpoint) {
                        case Some(explicit) => Some(explicit)
                        case None => match (checkpointRepository) {
                            case Some(repository) => repository.loadLatest(
                                thread, projector.version, value.lane.protocol
                            )
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

    public func cancel(
        joinTimeoutMillis: Int64,
        reason!: ?CancellationReason = None
    ): Result<RuntimeSettlement> {
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict(
                    "runtime.no_active_run", "Thread has no active Run to cancel"
                )
            }
            match (transitionOwned(owned, RunState.Cancelling, reason: "cancel_requested")) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let _ = owned.lifecycle.scope.cancel(reason: reason)
            let report = owned.lifecycle.joinOwned(joinTimeoutMillis)
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
                    let _ = transitionOwned(
                        owned, RunState.RecoveryRequired,
                        reason: "durable_cancel_failed"
                    )
                    return Result.Err(error)
            }
            let _ = owned.lifecycle.machine.commitPreview(terminalProposal).value().getOrThrow()
            let _ = coordinator.recordRunTransition(
                owned.turnId, owned.runId, owned.epoch, terminalProposal, finishedAtMillis
            )
            let run = activeSnapshot(owned)
            active = None
            Result.Ok(RuntimeSettlement(thread, run, report))
        } finally {
            lock.unlock()
        }
    }

    public func finish(
        terminal: RunState,
        joinTimeoutMillis: Int64,
        reason!: String = ""
    ): Result<RuntimeSettlement> {
        if (terminal != RunState.Completed && terminal != RunState.Failed &&
            terminal != RunState.RecoveryRequired) {
            return runtimeConflict(
                "runtime.invalid_terminal", "Run may finish only as completed, failed, or recovery-required"
            )
        }
        lock.lock()
        try {
            let owned = match (active) {
                case Some(value) => value
                case None => return runtimeConflict(
                    "runtime.no_active_run", "Thread has no active Run to finish"
                )
            }
            let report = owned.lifecycle.joinOwned(joinTimeoutMillis)
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
                    let _ = transitionOwned(
                        owned, RunState.RecoveryRequired,
                        reason: "durable_settlement_failed"
                    )
                    return Result.Err(error)
            }
            let _ = owned.lifecycle.machine.commitPreview(terminalProposal).value().getOrThrow()
            let _ = coordinator.recordRunTransition(
                owned.turnId, owned.runId, owned.epoch, terminalProposal, finishedAtMillis
            )
            let run = activeSnapshot(owned)
            active = None
            Result.Ok(RuntimeSettlement(thread, run, report))
        } finally {
            lock.unlock()
        }
    }

    private func activeSnapshot(value: OwnedActiveRun): ActiveRunSnapshot {
        let (state, sequence) = value.lifecycle.machine.snapshot()
        ActiveRunSnapshot(
            coordinator.snapshot().thread.id,
            value.turnId, value.runId, value.epoch, value.lane, value.skills,
            state, sequence
        )
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
