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

class OwnedRunTask {
    let name: String
    private let future: Future<Unit>
    private let lock = Mutex()
    private var settled = false
    private var failure = ""

    init(name: String, future: Future<Unit>) {
        this.name = name
        this.future = future
    }

    func observe(): Unit {
        let _ = spawn {
            try {
                future.get()
                recordSettlement("")
            } catch (error: Exception) {
                recordSettlement(error.message)
            }
        }
    }

    func snapshot(): (Bool, String) {
        lock.lock()
        try { (settled, failure) } finally { lock.unlock() }
    }

    private func recordSettlement(value: String): Unit {
        lock.lock()
        try {
            settled = true
            failure = value
        } finally { lock.unlock() }
    }
}

// A RunScope owns every asynchronous child. Terminal Run state is only
// published after join() has classified each child as joined or quarantined.
public class RunScope {
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

    public func own(name: String, future: Future<Unit>): Result<Unit> {
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
            let task = OwnedRunTask(name.trimAscii(), future)
            tasks.add(task)
            // Future.tryGet() is not a safe liveness probe for work blocked in
            // a foreign/native call: some runtime implementations wait on the
            // Future's internal completion lock.  A separate observer owns the
            // only blocking get(), while join() reads this independent marker.
            task.observe()
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func cancel(reason!: ?CancellationReason = None): Bool {
        source.cancel(reason: reason)
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
            } else if (failure != "") {
                settlements.add(OwnedTaskSettlement(
                    task.name, OwnedTaskOutcome.Failed, failure: failure
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
