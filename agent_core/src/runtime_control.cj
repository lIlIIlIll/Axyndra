package agent_core

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import std.collection.*
import std.sync.*
import tool_runtime.*

class CoreRunControl {
    let runId: RunId
    let traceId: TraceId
    let source: CancellationSource
    let runtime: AgentThreadRuntime
    let ledger: ExecutionBudget
    private let lock = Mutex()
    private var currentState: RunState
    private var requestCounter: Int64 = 0
    private var turnCounter: Int64 = 0
    private var batchCounter: Int64 = 0
    private var activeRequestId = ""
    private var activeTurnId: ?TurnId = None
    private var activeBatchId: ?ToolBatchId = None
    private var cancellationRegistration: ?CancellationRegistration = None

    init(
        runId: RunId,
        budget: ResourceBudget,
        runtime: AgentThreadRuntime,
        initial!: RunState = RunState.Running,
        turns!: Int64 = 0,
        modelRequests!: Int64 = 0
    ) {
        this.runId = runId
        this.traceId = TraceId("trace-" + runId.value)
        let execution = executionBudgetFrom(budget)
        this.source = CancellationSource(deadlineMillis: execution.deadlineMillis)
        this.runtime = runtime
        this.currentState = initial
        this.ledger = execution
        this.turnCounter = turns
        this.requestCounter = modelRequests
    }

    func state(): RunState {
        lock.lock()
        try { currentState } finally { lock.unlock() }
    }

    func pauseForApproval(): Result<RunTransition> {
        updateState(runtime.pauseForApproval())
    }

    func resumeAfterApproval(): Result<RunTransition> {
        updateState(runtime.resumeAfterApproval())
    }

    func finish(
        terminal: RunState,
        reason!: String = ""
    ): Result<RunTransition> {
        let from = state()
        let settlement = match (runtime.finish(terminal, 1000, reason: reason)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let transition = RunTransition(
            settlement.run.transitionSequence,
            from,
            settlement.run.state,
            reason
        )
        setState(settlement.run.state)
        Result.Ok(transition)
    }

    func settleCancellation(reason: CancellationReason): Result<Array<RunTransition>> {
        let from = state()
        let settlement = match (runtime.cancel(1000, reason: Some(reason))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let terminal = settlement.run.state
        let transitions = if (from == RunState.Cancelling) {
            [RunTransition(
                settlement.run.transitionSequence,
                RunState.Cancelling,
                terminal,
                reason.code
            )]
        } else {
            [
                RunTransition(
                    settlement.run.transitionSequence - 1,
                    from,
                    RunState.Cancelling,
                    reason.code
                ),
                RunTransition(
                    settlement.run.transitionSequence,
                    RunState.Cancelling,
                    terminal,
                    reason.code
                )
            ]
        }
        setState(terminal)
        Result.Ok(transitions)
    }

    private func updateState(result: Result<RunTransition>): Result<RunTransition> {
        match (result) {
            case Result.Ok(value) =>
                setState(value.to)
                Result.Ok(value)
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func setState(value: RunState): Unit {
        lock.lock()
        try { currentState = value } finally { lock.unlock() }
    }

    func bindCancellation(model: ModelPort, tools: ToolPipeline): Unit {
        let registration = source.token.onCancel({ _ =>
            let requestId = currentRequestId()
            if (requestId != "") {
                let _ = model.cancel(requestId)
            }
            // Older provider adapters used runId as requestId. Keeping this
            // fallback makes cancellation safe during the v3 cut-over.
            if (requestId != runId.value) {
                let _ = model.cancel(runId.value)
            }
            let _ = tools.cancel(runId)
        })
        lock.lock()
        try {
            cancellationRegistration = Some(registration)
        } finally {
            lock.unlock()
        }
    }

    func close(): Unit {
        lock.lock()
        let registration = try {
            let value = cancellationRegistration
            cancellationRegistration = None
            value
        } finally {
            lock.unlock()
        }
        match (registration) {
            case Some(value) => value.dispose()
            case None => ()
        }
        source.close()
    }

    func nextTurnId(): TurnId {
        lock.lock()
        try {
            turnCounter += 1
            let value = TurnId(runId.value + "-turn-" + turnCounter.toString())
            activeTurnId = Some(value)
            value
        } finally {
            lock.unlock()
        }
    }

    func nextRequestId(): RequestId {
        lock.lock()
        try {
            requestCounter += 1
            RequestId(runId.value + "-request-" + requestCounter.toString())
        } finally {
            lock.unlock()
        }
    }

    func nextBatchId(): ToolBatchId {
        lock.lock()
        try {
            batchCounter += 1
            let value = ToolBatchId(runId.value + "-tools-" + batchCounter.toString())
            activeBatchId = Some(value)
            value
        } finally {
            lock.unlock()
        }
    }

    func setActiveRequest(requestId: String): Unit {
        lock.lock()
        try { activeRequestId = requestId } finally { lock.unlock() }
    }

    func clearActiveRequest(requestId: String): Unit {
        lock.lock()
        try {
            if (activeRequestId == requestId) { activeRequestId = "" }
        } finally {
            lock.unlock()
        }
    }

    func currentRequestId(): String {
        lock.lock()
        try { activeRequestId } finally { lock.unlock() }
    }

    func currentTurnId(): ?TurnId {
        lock.lock()
        try { activeTurnId } finally { lock.unlock() }
    }

    func currentBatchId(): ?ToolBatchId {
        lock.lock()
        try { activeBatchId } finally { lock.unlock() }
    }

    func clearBatch(batchId: ToolBatchId): Unit {
        lock.lock()
        try {
            match (activeBatchId) {
                case Some(value) => if (value.value == batchId.value) { activeBatchId = None }
                case None => ()
            }
        } finally {
            lock.unlock()
        }
    }

    func reserve(charge: BudgetCharge): Result<ExecutionUsage> {
        match (ledger.reserve(charge)) {
            case Result.Ok(value) => Result.Ok(value)
            case Result.Err(error) =>
                let _ = source.cancel(reason: Some(CancellationReason(
                    CancellationReasonKind.Budget,
                    error.code,
                    error.message,
                    cancelledAtMillis: agentUtcMillis()
                )))
                Result.Err(error)
        }
    }

    func requestCancel(
        kind: CancellationReasonKind,
        code: String,
        message: String
    ): Bool {
        source.cancel(reason: Some(CancellationReason(
            kind,
            code,
            message,
            cancelledAtMillis: agentUtcMillis()
        )))
    }
}

class CoreRunControlRegistry {
    private let lock = Mutex()
    private let values = ArrayList<CoreRunControl>()

    func add(value: CoreRunControl): Result<Unit> {
        lock.lock()
        try {
            for (existing in values where existing.runId.value == value.runId.value) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.already_active",
                    "run already has an active control plane"
                ))
            }
            values.add(value)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    func find(runId: RunId): ?CoreRunControl {
        lock.lock()
        try {
            for (value in values where value.runId.value == runId.value) {
                return Some(value)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    func remove(runId: RunId): ?CoreRunControl {
        lock.lock()
        try {
            for (index in 0..values.size where values[index].runId.value == runId.value) {
                let value = values[index]
                values.remove(at: index)
                return Some(value)
            }
            None
        } finally {
            lock.unlock()
        }
    }
}
