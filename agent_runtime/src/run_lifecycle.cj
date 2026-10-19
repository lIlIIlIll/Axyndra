package agent_runtime

import std.collection.*
import std.deriving.*
import std.sync.*
import std.time.*
import agent_domain.*

public class RunTransition {
    public let sequence: Int64
    public let from: RunState
    public let to: RunState
    public let reason: String

    public init(
        sequence: Int64,
        from: RunState,
        to: RunState,
        reason: String
    ) {
        this.sequence = sequence
        this.from = from
        this.to = to
        this.reason = reason
    }
}

public class RunStateMachine {
    private let lock = Mutex()
    private var current: RunState
    private var sequence: Int64

    public init(
        initial!: RunState = RunState.Created,
        sequence!: Int64 = 0
    ) {
        if (sequence < 0) {
            throw IllegalArgumentException("run transition sequence must not be negative")
        }
        this.current = initial
        this.sequence = sequence
    }

    public func snapshot(): (RunState, Int64) {
        lock.lock()
        try { (current, sequence) } finally { lock.unlock() }
    }

    public func state(): RunState {
        let (value, _) = snapshot()
        value
    }

    public func transition(
        to: RunState,
        reason!: String = ""
    ): Result<RunTransition> {
        let proposal = match (preview(to, reason: reason)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        commitPreview(proposal)
    }

    public func preview(
        to: RunState,
        reason!: String = ""
    ): Result<RunTransition> {
        lock.lock()
        try {
            if (!legalRunTransition(current, to)) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.invalid_transition",
                    "run cannot transition from " + runStateName(current) +
                        " to " + runStateName(to)
                ))
            }
            if (sequence == Int64.Max) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.sequence_exhausted",
                    "run transition sequence is exhausted"
                ))
            }
            Result.Ok(RunTransition(sequence + 1, current, to, reason))
        } finally {
            lock.unlock()
        }
    }

    public func commitPreview(proposal: RunTransition): Result<RunTransition> {
        lock.lock()
        try {
            if (proposal.from != current || proposal.sequence != sequence + 1 ||
                !legalRunTransition(current, proposal.to)) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.stale_transition",
                    "run transition proposal no longer owns the current state"
                ))
            }
            sequence = proposal.sequence
            current = proposal.to
            Result.Ok(proposal)
        } finally {
            lock.unlock()
        }
    }
}

public func legalRunTransition(from: RunState, to: RunState): Bool {
    match ((from, to)) {
        case (RunState.Created, RunState.Running) |
             (RunState.Created, RunState.Failed) |
             (RunState.Created, RunState.RecoveryRequired) |
             (RunState.Running, RunState.WaitingApproval) |
             (RunState.Running, RunState.WaitingExternal) |
             (RunState.Running, RunState.Cancelling) |
             (RunState.Running, RunState.Completed) |
             (RunState.Running, RunState.Failed) |
             (RunState.Running, RunState.RecoveryRequired) |
             (RunState.WaitingApproval, RunState.Running) |
             (RunState.WaitingApproval, RunState.Cancelling) |
             (RunState.WaitingApproval, RunState.Failed) |
             (RunState.WaitingApproval, RunState.RecoveryRequired) |
             (RunState.WaitingExternal, RunState.Running) |
             (RunState.WaitingExternal, RunState.Cancelling) |
             (RunState.WaitingExternal, RunState.Failed) |
             (RunState.WaitingExternal, RunState.RecoveryRequired) |
             (RunState.Cancelling, RunState.Cancelled) |
             (RunState.Cancelling, RunState.Failed) |
             (RunState.Cancelling, RunState.RecoveryRequired) => true
        case _ => false
    }
}

@Derive[Equatable]
public enum OwnedTaskOutcome {
    Joined | Failed | Quarantined
}

public class OwnedTaskSettlement {
    public let name: String
    public let outcome: OwnedTaskOutcome
    public let failure: String

    public init(name: String, outcome: OwnedTaskOutcome, failure!: String = "") {
        this.name = name
        this.outcome = outcome
        this.failure = failure
    }
}

public class RunJoinReport {
    public let settlements: Array<OwnedTaskSettlement>

    public init(settlements: Array<OwnedTaskSettlement>) {
        this.settlements = settlements
    }

    public func quarantinedCount(): Int64 {
        var count: Int64 = 0
        for (item in settlements where item.outcome == OwnedTaskOutcome.Quarantined) {
            count += 1
        }
        count
    }

    public func failedCount(): Int64 {
        var count: Int64 = 0
        for (item in settlements where item.outcome == OwnedTaskOutcome.Failed) {
            count += 1
        }
        count
    }
}

// A terminal state may not claim stronger knowledge than the owned task tree.
// Quarantined work is still running or unobservable, while an observed child
// failure disproves successful completion.
public func effectiveRunTerminal(
    requested: RunState,
    report: RunJoinReport
): RunState {
    if (report.quarantinedCount() > 0) {
        RunState.RecoveryRequired
    } else if (requested == RunState.Completed && report.failedCount() > 0) {
        RunState.Failed
    } else {
        requested
    }
}

public type RunTaskJoin = () -> Result<Unit>

class OwnedRunTask {
    let name: String
    let blocksModelBoundary: Bool
    private let future: Future<Unit>
    private let lock = Mutex()
    private var settled = false
    private var failure: ?String = None
    private var observer113: ?Future<Unit> = None<Future<Unit>>
    private var observerReturned113 = false

    init(name: String, future: Future<Unit>, blocksModelBoundary: Bool) {
        this.name = name
        this.future = future
        this.blocksModelBoundary = blocksModelBoundary
    }

    func observe(): Unit {
        let actual = spawn {
            try {
                future.get()
                recordSettlement(None)
            } catch (error: Exception) {
                recordSettlement(Some(error.message))
            }
        }
        lock.lock(); try { observer113 = Some(actual) } finally { lock.unlock() }
    }

    // Settlement proves target.get returned, then exact observer.get proves
    // its metadata/catch helper also returned. No Future.tryGet is called on
    // foreign-blocked work. Unknown observer remains paid/unreturned.
    func completeReturnWitness113(): Bool {
        lock.lock()
        let selected = try {
            if (observerReturned113) { return true }
            if (!settled) { return false }
            observer113
        } finally { lock.unlock() }
        let actual = match (selected) { case Some(value) => value; case None => return false }
        try { actual.get() } catch (_: Exception) { return false }
        // Exact get helper returns before callers release the scope alias.
        lock.lock(); try { observer113 = None<Future<Unit>>; observerReturned113 = true } finally { lock.unlock() }
        true
    }

    func snapshot(): (Bool, ?String) {
        lock.lock()
        try { (settled, failure) } finally { lock.unlock() }
    }

    // Called only by the host-held join handle, outside the Run/task locks.
    // Both this and the existing observer record the same Future completion.
    func join(): Result<Unit> {
        try { future.get(); recordSettlement(None); Result.Ok(()) }
        catch (error: Exception) {
            recordSettlement(Some(error.message))
            Result.Err(AgentError(AgentErrorKind.Internal, "run.owned_task_failed", "owned task failed while joining"))
        }
    }

    private func recordSettlement(value: ?String): Unit {
        lock.lock()
        try {
            settled = true
            failure = value
        } finally { lock.unlock() }
    }
}

// A RunScope owns every asynchronous child. Terminal Run state is only
// published after join() has classified each child as joined or quarantined.
// DATA-only return witness over the SAME already-owned task list.
// It creates no Run, Source, Future, task registry, error copy or new pool.
public interface OwnedTaskReturnWitness113 {
    func allOwnedProducersReturned113(): Bool
}

public class RunScope <: OwnedTaskReturnWitness113 {
    private let lock = Mutex()
    private let source: CancellationSource
    private let tasks = ArrayList<OwnedRunTask>()
    private let childSources = ArrayList<CancellationSource>()
    private var joining: Bool = false
    private var joined: Bool = false

    public init(deadlineMillis!: Int64 = 0, parent!: ?CancellationToken = None) {
        source = CancellationSource(parent: parent, deadlineMillis: deadlineMillis)
    }

    public prop token: CancellationToken { get() { source.token } }

    public func childToken(deadlineMillis!: Int64 = 0): CancellationToken {
        lock.lock()
        try {
            if (joining || joined) {
                throw IllegalStateException("run scope no longer accepts children")
            }
            let child = source.child(deadlineMillis: deadlineMillis)
            childSources.add(child)
            child.token
        } finally {
            lock.unlock()
        }
    }

    public func own(name: String, future: Future<Unit>, blocksModelBoundary!: Bool = false): Result<Unit> {
        match (ownWithJoin(name, future, blocksModelBoundary: blocksModelBoundary)) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    // Same admission and same task list; the returned host-only closure can
    // synchronously observe this exact Future after resource cleanup ACK.
    public func ownWithJoin(name: String, future: Future<Unit>,
        blocksModelBoundary!: Bool = false): Result<RunTaskJoin> {
        if (name.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "run.task_name_empty",
                "owned run task name must not be empty"
            ))
        }
        lock.lock()
        try {
            if (joining || joined) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.scope_settling",
                    "run scope no longer accepts owned work"
                ))
            }
            for (task in tasks where task.name == name) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.duplicate_owned_task",
                    "run scope already owns a task with this name"
                ))
            }
            let task = OwnedRunTask(name.trimAscii(), future, blocksModelBoundary)
            tasks.add(task)
            // Future.tryGet() is not a safe liveness probe for work blocked in
            // a foreign/native call: some runtime implementations wait on the
            // Future's internal completion lock. A separate observer performs
            // get(), while bounded Run join reads this independent marker.
            // The optional host join handle is used only after resource ACK.
            task.observe()
            Result.Ok({ => task.join() })
        } finally {
            lock.unlock()
        }
    }

    public func cancel(reason!: ?CancellationReason = None): Bool {
        source.cancel(reason: reason)
    }

    // This is metadata on the same owned task list, not another debt registry.
    // Ordinary background tasks keep their existing safe-cut behavior.
    public func hasPendingModelBoundaryTask(): Bool {
        lock.lock()
        try {
            for (task in tasks where task.blocksModelBoundary) {
                let (settled, _) = task.snapshot()
                if (!settled) { return true }
            }
            false
        } finally { lock.unlock() }
    }

    func withSettledDataProjection(action: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (joining || joined || source.token.isCancelled()) {
                return directPostCanonicalProjectionFailure("runtime.projection_scope_not_current") }
            for (task in tasks) {
                let (settled, failure) = task.snapshot()
                if (!settled || failure.isSome()) {
                    return directPostCanonicalProjectionFailure("runtime.projection_physical_ack_pending") }
            }
            // ownWithJoin needs this same lock, so no new physical task can
            // race the final SQL current check and disposable INSERT.
            action()
        } finally { lock.unlock() }
    }

    // A target's settlement is recorded only AFTER exact Future.get returns.
    // Cancellation, finally/completed flags and a quarantined report are not
    // return witnesses. No tryGet/native completion lock is queried here.
    public func allOwnedProducersReturned113(): Bool {
        lock.lock()
        try {
            if (!joined || joining) { return false }
            for (task in tasks) {
                if (!task.completeReturnWitness113()) { return false }
            }
            true
        } finally { lock.unlock() }
    }

    public func join(timeoutMillis: Int64): RunJoinReport {
        if (timeoutMillis < 0) {
            throw IllegalArgumentException("run join timeout must not be negative")
        }
        var owned: Array<OwnedRunTask> = []
        lock.lock()
        try {
            if (joining || joined) {
                throw IllegalStateException("run scope may only be joined once")
            }
            joining = true
            owned = tasks.toArray()
        } finally {
            lock.unlock()
        }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        while (hasPending(owned) && MonoTime.now() < deadline) {
            sleep(Duration.millisecond)
        }
        let settlements = ArrayList<OwnedTaskSettlement>()
        for (task in owned) {
            let (settled, failure) = task.snapshot()
            if (!settled) {
                settlements.add(OwnedTaskSettlement(
                    task.name, OwnedTaskOutcome.Quarantined
                ))
            } else if (failure.isSome()) {
                settlements.add(OwnedTaskSettlement(
                    task.name, OwnedTaskOutcome.Failed, failure: failure.getOrThrow()
                ))
            } else {
                settlements.add(OwnedTaskSettlement(task.name, OwnedTaskOutcome.Joined))
            }
        }
        lock.lock()
        try {
            joining = false
            joined = true
            for (child in childSources) { child.close() }
            childSources.clear()
            source.close()
        } finally {
            lock.unlock()
        }
        RunJoinReport(settlements.toArray())
    }
}

func hasPending(tasks: Array<OwnedRunTask>): Bool {
    for (task in tasks) {
        let (settled, _) = task.snapshot()
        if (!settled) { return true }
    }
    false
}

public class RunLifecycle {
    public let machine: RunStateMachine
    public let scope: RunScope

    public init(
        deadlineMillis!: Int64 = 0,
        parent!: ?CancellationToken = None,
        initialState!: RunState = RunState.Created,
        transitionSequence!: Int64 = 0
    ) {
        machine = RunStateMachine(initial: initialState, sequence: transitionSequence)
        scope = RunScope(deadlineMillis: deadlineMillis, parent: parent)
    }

    public func start(): Result<RunTransition> {
        machine.transition(RunState.Running)
    }

    public func requestCancel(reason!: ?CancellationReason = None): Result<RunTransition> {
        let transition = machine.transition(RunState.Cancelling, reason: "cancel_requested")
        match (transition) {
            case Result.Ok(_) => let _ = scope.cancel(reason: reason)
            case Result.Err(_) => ()
        }
        transition
    }

    public func settleCancelled(joinTimeoutMillis: Int64): (RunTransition, RunJoinReport) {
        settle(RunState.Cancelled, joinTimeoutMillis)
    }

    public func joinOwned(joinTimeoutMillis: Int64): RunJoinReport {
        scope.join(joinTimeoutMillis)
    }

    public func commitTerminal(
        terminal: RunState,
        report: RunJoinReport,
        reason!: String = ""
    ): Result<RunTransition> {
        if (!isTerminalRunState(terminal)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "run.terminal_required",
                "run settlement requires a terminal state"
            ))
        }
        let quarantine = report.quarantinedCount()
        let settlementReason = if (reason != "") {
            reason
        } else if (quarantine > 0) {
            "quarantined=" + quarantine.toString()
        } else if (report.failedCount() > 0) {
            "owned_failures=" + report.failedCount().toString()
        } else {
            "joined"
        }
        machine.transition(terminal, reason: settlementReason)
    }

    public func settle(
        terminal: RunState,
        joinTimeoutMillis: Int64,
        reason!: String = ""
    ): (RunTransition, RunJoinReport) {
        if (!isTerminalRunState(terminal)) {
            throw IllegalArgumentException("run settlement requires a terminal state")
        }
        let report = joinOwned(joinTimeoutMillis)
        let transition = commitTerminal(
            effectiveRunTerminal(terminal, report), report, reason: reason
        ).value().getOrThrow()
        (transition, report)
    }
}
