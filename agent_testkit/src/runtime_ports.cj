package agent_testkit

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.sync.*

class MemoryRunRecord {
    var snapshot: RunSnapshot
    let eventValues = ArrayList<AgentEvent>()
    var continuationValue: ?RunContinuation = None
    let attempts = ArrayList<DurableModelAttempt>()

    init(snapshot: RunSnapshot) { this.snapshot = snapshot }
}

public class MemoryRunRepository <: RunRepository {
    private let lock = Mutex()
    private let records = ArrayList<MemoryRunRecord>()
    private let decisions = ArrayList<ApprovalDecisionReceipt>()

    public init() {}

    public func save(snapshot: RunSnapshot): Result<Unit> {
        lock.lock()
        try {
            match (record(snapshot.runId.value)) {
                case Some(value) =>
                    if (value.snapshot.sessionId.value != snapshot.sessionId.value) {
                        return memoryConflict<Unit>("run cannot move to another session")
                    }
                    value.snapshot = snapshot
                case None => records.add(MemoryRunRecord(snapshot))
            }
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        lock.lock()
        try {
            match (record(runId.value)) {
                case Some(value) => Result.Ok(value.snapshot)
                case None => missingMemoryValue<RunSnapshot>("run", runId.value)
            }
        } finally { lock.unlock() }
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        lock.lock()
        try {
            let value = match (record(runId.value)) {
                case Some(item) => item
                case None => return missingMemoryValue<EventPage>("run", runId.value)
            }
            let selected = ArrayList<AgentEvent>()
            var next = after + 1
            for (event in value.eventValues where event.sequence > after) {
                selected.add(event)
                next = event.sequence + 1
            }
            Result.Ok(EventPage(selected.toArray(), next))
        } finally { lock.unlock() }
    }

    public func append(event: AgentEvent): Result<Unit> {
        lock.lock()
        try {
            match (record(event.runId.value)) {
                case Some(value) =>
                    let expected = if (value.eventValues.isEmpty()) { 1 } else {
                        value.eventValues[value.eventValues.size - 1].sequence + 1
                    }
                    if (event.sequence != expected) {
                        return memoryConflict<Unit>("event sequence must increase monotonically")
                    }
                    value.eventValues.add(event)
                    Result.Ok(())
                case None => missingMemoryValue<Unit>("run", event.runId.value)
            }
        } finally { lock.unlock() }
    }

    public func saveContinuation(value: RunContinuation): Result<Unit> {
        lock.lock()
        try {
            match (record(value.runId.value)) {
                case Some(item) =>
                    if (item.snapshot.sessionId.value != value.sessionId.value) {
                        return memoryConflict<Unit>("run continuation belongs to another session")
                    }
                    if (value.kind == RunContinuationKind.WaitingApproval &&
                        (value.approval.sessionId != value.sessionId.value ||
                        value.approval.callId == "" || value.approval.argumentHash == "")) {
                        return memoryConflict<Unit>("pending approval continuation binding is incomplete")
                    }
                    match (item.continuationValue) {
                        case Some(existing) => if (sameContinuationBinding(existing, value)) {
                            Result.Ok(())
                        } else if (approvedContinuationTransition(existing, value, decisionRecord(
                            existing.approval.operationId.value
                        ))) {
                            item.continuationValue = Some(value)
                            Result.Ok(())
                        } else {
                            memoryConflict<Unit>("pending approval continuation binding cannot be changed")
                        }
                        case None =>
                            item.continuationValue = Some(value)
                            Result.Ok(())
                    }
                case None => missingMemoryValue<Unit>("run", value.runId.value)
            }
        } finally { lock.unlock() }
    }

    public func continuation(runId: RunId): Result<RunContinuation> {
        lock.lock()
        try {
            match (record(runId.value)) {
                case Some(item) => match (item.continuationValue) {
                    case Some(value) => Result.Ok(value)
                    case None => memoryRecoveryRequired<RunContinuation>(
                        runId.value,
                        "pending approval continuation is missing"
                    )
                }
                case None => memoryRecoveryRequired<RunContinuation>(
                    runId.value,
                    "run snapshot is missing"
                )
            }
        } finally { lock.unlock() }
    }

    public func pendingContinuation(sessionId: SessionId): Result<?RunContinuation> {
        lock.lock()
        try {
            var pending: ?MemoryRunRecord = None
            for (item in records where item.snapshot.sessionId.value == sessionId.value &&
                 item.snapshot.status == RunState.WaitingApproval) {
                if (pending.isSome()) {
                    return Result.Err(AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "run.multiple_pending_approvals",
                        "session has multiple pending approval runs",
                        fields: [ErrorField("session_id", sessionId.value)]
                    ))
                }
                pending = Some(item)
            }
            match (pending) {
                case None => Result.Ok(None)
                case Some(item) => match (item.continuationValue) {
                    case Some(value) => Result.Ok(Some(value))
                    case None => memoryRecoveryRequired<?RunContinuation>(
                        item.snapshot.runId.value,
                        "awaiting approval snapshot has no continuation"
                    )
                }
            }
        } finally { lock.unlock() }
    }

    public func pendingRecoveryContinuation(sessionId: SessionId): Result<?RunContinuation> {
        lock.lock()
        try {
            var pending: ?RunContinuation = None
            for (item in records where item.snapshot.sessionId.value == sessionId.value) {
                match (item.continuationValue) {
                    case Some(value) => if (value.kind == RunContinuationKind.RunningModel) {
                        if (pending.isSome()) {
                            return memoryRecoveryRequired<?RunContinuation>(
                                sessionId.value, "session has multiple pending model executions"
                            )
                        }
                        pending = Some(value)
                    }
                    case None => ()
                }
            }
            Result.Ok(pending)
        } finally { lock.unlock() }
    }

    public func compareAndSwapContinuation(
        expected: ?RunContinuation,
        next: RunContinuation
    ): Result<RunContinuation> {
        lock.lock()
        try {
            let value = match (record(next.runId.value)) {
                case Some(item) => item
                case None => return missingMemoryValue<RunContinuation>("run", next.runId.value)
            }
            if (!sameOptionalContinuation(value.continuationValue, expected)) {
                match (value.continuationValue) {
                    case Some(winner) => if (sameContinuationBinding(winner, next)) {
                        return Result.Ok(winner)
                    }
                    case None => ()
                }
                return memoryConflict<RunContinuation>("run continuation changed concurrently")
            }
            value.continuationValue = Some(next)
            Result.Ok(next)
        } finally { lock.unlock() }
    }

    public func prepareModelAttempt(
        attempt: DurableModelAttempt,
        event: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        lock.lock()
        try {
            let value = match (record(attempt.runId.value)) {
                case Some(item) => item
                case None => return missingMemoryValue<Unit>("run", attempt.runId.value)
            }
            var attemptExists = false
            for (existing in value.attempts where existing.id.value == attempt.id.value) {
                if (!sameMemoryAttempt(existing, attempt)) {
                    return memoryConflict<Unit>("model Attempt identity drift")
                }
                attemptExists = true
            }
            if (value.continuationValue.isSome() &&
                !sameContinuationBinding(value.continuationValue.getOrThrow(), continuation)) {
                let previous = value.continuationValue.getOrThrow()
                let approvedTransition = previous.kind == RunContinuationKind.WaitingApproval &&
                    continuation.kind == RunContinuationKind.RunningModel && match (decisionRecord(
                        previous.approval.operationId.value
                    )) {
                        case Some(receipt) =>
                            receipt.runId.value == continuation.runId.value &&
                                receipt.sessionId.value == continuation.sessionId.value
                        case None => false
                    }
                if (!approvedTransition) {
                    let previousCheckpoint = match (previous.runningModel) {
                        case Some(item) => item
                        case None => return memoryConflict<Unit>("model continuation changed concurrently")
                    }
                    if (match (attempt.parentAttemptId) {
                        case Some(parent) => parent.value != previousCheckpoint.activeAttemptId.value
                        case None => true
                    } || previousCheckpoint.semanticRequestId.value !=
                        continuation.runningModel.getOrThrow().semanticRequestId.value ||
                        previousCheckpoint.semanticRequestDigest !=
                        continuation.runningModel.getOrThrow().semanticRequestDigest) {
                        return memoryConflict<Unit>("model continuation changed concurrently")
                    }
                }
            }
            if (!value.eventValues.isEmpty() &&
                event.sequence != value.eventValues[value.eventValues.size - 1].sequence + 1) {
                if (memoryEventAppendDisposition(value.eventValues, event) < 0) {
                    return memoryConflict<Unit>("event sequence must increase monotonically")
                }
            }
            let eventDisposition = memoryEventAppendDisposition(value.eventValues, event)
            if (attemptExists) {
                let sameContinuation = match (value.continuationValue) {
                    case Some(existing) => sameContinuationBinding(existing, continuation)
                    case None => false
                }
                if (!sameContinuation || eventDisposition != 0) {
                    return memoryConflict<Unit>("prepared model boundary identity drift")
                }
                return Result.Ok(())
            }
            if (eventDisposition != 1) {
                return memoryConflict<Unit>("prepared model event identity drift")
            }
            value.attempts.add(attempt)
            value.continuationValue = Some(continuation)
            value.eventValues.add(event)
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func prepareRestartModelAttempt(
        parent: DurableModelAttempt,
        attempt: DurableModelAttempt,
        policyEvent: AgentEvent,
        duplicateEvent: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        lock.lock()
        try {
            let value = match (record(attempt.runId.value)) {
                case Some(item) => item
                case None => return missingMemoryValue<Unit>("run", attempt.runId.value)
            }
            let current = match (value.continuationValue) {
                case Some(item) => item
                case None => return memoryRecoveryRequired<Unit>(
                    attempt.runId.value, "restart continuation is missing"
                )
            }
            let currentCheckpoint = match (current.runningModel) {
                case Some(item) => item
                case None => return memoryRecoveryRequired<Unit>(
                    attempt.runId.value, "restart continuation is not running model"
                )
            }
            if (currentCheckpoint.activeAttemptId.value != parent.id.value ||
                attempt.parentAttemptId.isNone() ||
                attempt.parentAttemptId.getOrThrow().value != parent.id.value ||
                duplicateEvent.sequence != policyEvent.sequence + 1 ||
                memoryEventAppendDisposition(value.eventValues, policyEvent) != 1) {
                return memoryConflict<Unit>("restart model boundary identity drift")
            }
            var parentIndex: Int64 = -1
            for (index in 0..value.attempts.size where
                value.attempts[index].id.value == parent.id.value) {
                parentIndex = index
            }
            if (parentIndex < 0 ||
                value.attempts[parentIndex].dispatchState !=
                    ModelAttemptDispatchState.DispatchClaimed ||
                value.attempts[parentIndex].replayBarrier !=
                    ModelAttemptReplayBarrier.NoBarrier) {
                return memoryRecoveryRequired<Unit>(
                    parent.id.value, "restart parent Attempt is not recoverable"
                )
            }
            for (existing in value.attempts where existing.id.value == attempt.id.value) {
                return if (sameMemoryAttempt(existing, attempt)) { Result.Ok(()) } else {
                    memoryConflict<Unit>("restart child Attempt identity drift")
                }
            }
            value.attempts[parentIndex] = copyMemoryAttemptAbandoned(
                value.attempts[parentIndex], duplicateEvent.meta.occurredAtMillis
            )
            value.attempts.add(attempt)
            value.continuationValue = Some(continuation)
            value.eventValues.add(policyEvent)
            value.eventValues.add(duplicateEvent)
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func modelAttempt(attemptId: ModelAttemptId): Result<DurableModelAttempt> {
        lock.lock()
        try {
            for (value in records) { for (attempt in value.attempts where attempt.id.value == attemptId.value) {
                return Result.Ok(attempt)
            }}
            memoryRecoveryRequired<DurableModelAttempt>(attemptId.value, "durable model Attempt is missing")
        } finally { lock.unlock() }
    }

    public func claimModelAttemptDispatch(
        attemptId: ModelAttemptId,
        event: AgentEvent
    ): Result<Bool> {
        lock.lock()
        try {
            let value = match (record(event.runId.value)) {
                case Some(item) => item
                case None => return missingMemoryValue<Bool>("run", event.runId.value)
            }
            for (index in 0..value.attempts.size where value.attempts[index].id.value == attemptId.value) {
                let attempt = value.attempts[index]
                if (attempt.dispatchState == ModelAttemptDispatchState.DispatchClaimed) {
                    return Result.Ok(false)
                }
                if (attempt.dispatchState != ModelAttemptDispatchState.Prepared ||
                    attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
                    return memoryRecoveryRequired<Bool>(attemptId.value, "model Attempt is not dispatchable")
                }
                if (memoryEventAppendDisposition(value.eventValues, event) != 1) {
                    return memoryConflict<Bool>("model dispatch event sequence is invalid")
                }
                value.attempts[index] = copyMemoryAttemptDispatch(
                    attempt, event.meta.occurredAtMillis
                )
                value.eventValues.add(event)
                return Result.Ok(true)
            }
            memoryRecoveryRequired<Bool>(attemptId.value, "durable model Attempt is missing")
        } finally { lock.unlock() }
    }

    public func markModelAttemptReplayBarrier(
        attemptId: ModelAttemptId,
        barrier: ModelAttemptReplayBarrier,
        event: AgentEvent
    ): Result<Unit> {
        lock.lock()
        try {
            let value = match (record(event.runId.value)) {
                case Some(item) => item
                case None => return missingMemoryValue<Unit>("run", event.runId.value)
            }
            for (index in 0..value.attempts.size where value.attempts[index].id.value == attemptId.value) {
                let attempt = value.attempts[index]
                if (attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier &&
                    attempt.replayBarrier != barrier) {
                    return memoryConflict<Unit>("model replay barrier identity drift")
                }
                let eventDisposition = memoryEventAppendDisposition(value.eventValues, event)
                if (attempt.replayBarrier == barrier) {
                    if (eventDisposition == 0) { return Result.Ok(()) }
                    return memoryConflict<Unit>("model replay barrier event identity drift")
                }
                if (eventDisposition != 1) {
                    return memoryConflict<Unit>("model replay barrier event sequence is invalid")
                }
                value.attempts[index] = copyMemoryAttemptBarrier(attempt, barrier)
                value.eventValues.add(event)
                return Result.Ok(())
            }
            memoryRecoveryRequired<Unit>(attemptId.value, "durable model Attempt is missing")
        } finally { lock.unlock() }
    }

    public func clearModelExecutionContinuation(
        runId: RunId,
        activeAttemptId: ModelAttemptId
    ): Result<Unit> {
        lock.lock()
        try {
            let value = match (record(runId.value)) {
                case Some(item) => item
                case None => return missingMemoryValue<Unit>("run", runId.value)
            }
            match (value.continuationValue) {
                case Some(continuation) => match (continuation.runningModel) {
                    case Some(checkpoint) => if (checkpoint.activeAttemptId.value != activeAttemptId.value) {
                        return memoryConflict<Unit>("model continuation Attempt binding drift")
                    }
                    case None => return memoryConflict<Unit>("continuation is not a model execution")
                }
                case None => return Result.Ok(())
            }
            value.continuationValue = None
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func saveDecision(receipt: ApprovalDecisionReceipt): Result<Unit> {
        lock.lock()
        try {
            match (decisionRecord(receipt.operationId.value)) {
                case Some(existing) => if (sameDecisionBinding(existing, receipt)) {
                    Result.Ok(())
                } else {
                    memoryConflict<Unit>("approval decision binding changed")
                }
                case None =>
                    decisions.add(receipt)
                    Result.Ok(())
            }
        } finally { lock.unlock() }
    }

    public func decision(operationId: OperationId): Result<ApprovalDecisionReceipt> {
        lock.lock()
        try {
            match (decisionRecord(operationId.value)) {
                case Some(value) => Result.Ok(value)
                case None => missingMemoryValue<ApprovalDecisionReceipt>("decision", operationId.value)
            }
        } finally { lock.unlock() }
    }

    public func recordDecision(receipt: ApprovalDecisionReceipt): Result<RunSnapshot> {
        lock.lock()
        try {
            let item = match (record(receipt.runId.value)) {
                case Some(value) => value
                case None => return memoryRecoveryRequired<RunSnapshot>(
                    receipt.runId.value,
                    "approval decision run snapshot is missing"
                )
            }
            if (item.snapshot.sessionId.value != receipt.sessionId.value) {
                return memoryRecoveryRequired<RunSnapshot>(
                    receipt.runId.value,
                    "approval decision run binding is corrupt"
                )
            }
            match (item.continuationValue) {
                case Some(value) => if (!continuationAcceptsDecision(value, receipt)) {
                    return memoryRecoveryRequired<RunSnapshot>(
                        receipt.runId.value,
                        "approval decision does not match the pending continuation"
                    )
                }
                case None => if (item.snapshot.status == RunState.WaitingApproval) {
                    return memoryRecoveryRequired<RunSnapshot>(
                        receipt.runId.value,
                        "awaiting approval run has no continuation"
                    )
                }
            }
            let existing = decisionRecord(receipt.operationId.value)
            match (item.snapshot.status) {
                case RunState.WaitingApproval => match (existing) {
                    case Some(value) => if (sameDecisionBinding(value, receipt)) {
                        Result.Ok(item.snapshot)
                    } else {
                        memoryConflict<RunSnapshot>("approval decision binding changed")
                    }
                    case None =>
                        decisions.add(receipt)
                        Result.Ok(item.snapshot)
                }
                case RunState.Completed => match (existing) {
                    case Some(value) => if (sameDecisionBinding(value, receipt)) {
                        Result.Ok(item.snapshot)
                    } else {
                        memoryConflict<RunSnapshot>("completed approval decision binding changed")
                    }
                    case None => memoryRecoveryRequired<RunSnapshot>(
                        receipt.runId.value,
                        "completed approval run has no durable decision receipt"
                    )
                }
                case _ => memoryConflict<RunSnapshot>("run is not awaiting approval")
            }
        } finally { lock.unlock() }
    }

    private func record(runId: String): ?MemoryRunRecord {
        for (value in records where value.snapshot.runId.value == runId) { return Some(value) }
        None
    }

    private func decisionRecord(operationId: String): ?ApprovalDecisionReceipt {
        for (value in decisions where value.operationId.value == operationId) { return Some(value) }
        None
    }
}

class MemoryOperationRecord {
    var value: OperationRecord
    var receiptValue: ?OperationReceipt = None

    init(value: OperationRecord) { this.value = value }
}

public class MemoryOperationRepository <: OperationRepository {
    private let lock = Mutex()
    private let records = ArrayList<MemoryOperationRecord>()

    public init() {}

    public func prepare(record: OperationRecord): Result<Unit> {
        lock.lock()
        try {
            match (entry(record.operationId.value)) {
                case Some(existing) => if (existing.value.requestDigest == record.requestDigest) {
                    Result.Ok(())
                } else {
                    memoryConflict<Unit>("operation digest changed")
                }
                case None =>
                    records.add(MemoryOperationRecord(record))
                    Result.Ok(())
            }
        } finally { lock.unlock() }
    }

    public func transition(
        operationId: OperationId,
        expected: OperationStatus,
        next: OperationStatus
    ): Result<Unit> {
        lock.lock()
        try {
            let item = match (entry(operationId.value)) {
                case Some(value) => value
                case None => return missingMemoryValue<Unit>("operation", operationId.value)
            }
            if (item.value.status != expected) {
                return memoryConflict<Unit>("operation state changed")
            }
            let current = item.value
            item.value = OperationRecord(
                current.operationId,
                current.runId,
                next,
                current.capability,
                current.requestDigest,
                call: current.call
            )
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func find(operationId: OperationId): Result<OperationRecord> {
        lock.lock()
        try {
            match (entry(operationId.value)) {
                case Some(value) => Result.Ok(value.value)
                case None => missingMemoryValue<OperationRecord>("operation", operationId.value)
            }
        } finally { lock.unlock() }
    }

    public func receipt(operationId: OperationId): Result<OperationReceipt> {
        lock.lock()
        try {
            match (entry(operationId.value)) {
                case Some(item) => match (item.receiptValue) {
                    case Some(value) => Result.Ok(value)
                    case None => missingMemoryValue<OperationReceipt>("receipt", operationId.value)
                }
                case None => missingMemoryValue<OperationReceipt>("operation", operationId.value)
            }
        } finally { lock.unlock() }
    }

    public func saveReceipt(receipt: OperationReceipt): Result<Unit> {
        lock.lock()
        try {
            match (entry(receipt.operationId.value)) {
                case Some(item) => match (item.receiptValue) {
                    case Some(existing) => if (
                        existing.committed == receipt.committed &&
                        existing.isError == receipt.isError &&
                        agentValuesEqual(existing.detail, receipt.detail)
                    ) {
                        Result.Ok(())
                    } else {
                        memoryConflict<Unit>("operation receipt cannot be overwritten")
                    }
                    case None =>
                        item.receiptValue = Some(receipt)
                        Result.Ok(())
                }
                case None => missingMemoryValue<Unit>("operation", receipt.operationId.value)
            }
        } finally { lock.unlock() }
    }

    public func receiptCount(): Int64 {
        lock.lock()
        try {
            var count: Int64 = 0
            for (item in records) {
                if (item.receiptValue.isSome()) { count += 1 }
            }
            count
        } finally { lock.unlock() }
    }

    private func entry(operationId: String): ?MemoryOperationRecord {
        for (value in records where value.value.operationId.value == operationId) { return Some(value) }
        None
    }
}

public class RecordingAuditPort <: AuditPort {
    private let lock = Mutex()
    private let values = ArrayList<AgentEvent>()

    public init() {}

    public func append(event: AgentEvent): Result<Unit> {
        lock.lock()
        try {
            values.add(event)
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func events(): Array<AgentEvent> {
        lock.lock()
        try { values.toArray() } finally { lock.unlock() }
    }
}

func agentValuesEqual(left: AgentValue, right: AgentValue): Bool {
    if (left.unifiedKind != right.unifiedKind) { return false }
    match (left.unifiedKind) {
        case ValueKind.Null => true
        case ValueKind.Boolean => left.boolean == right.boolean
        case ValueKind.Number => left.number == right.number
        case ValueKind.Text => left.text == right.text
        case ValueKind.List =>
            if (left.items.size != right.items.size) { return false }
            for (index in 0..left.items.size) {
                if (!agentValuesEqual(left.items[index], right.items[index])) { return false }
            }
            true
        case ValueKind.Object =>
            if (left.fields.size != right.fields.size) { return false }
            for (field in left.fields) {
                match (right.field(field.name)) {
                    case Some(value) => if (!agentValuesEqual(field.value, value)) { return false }
                    case None => return false
                }
            }
            true
    }
}

func sameContinuationBinding(left: RunContinuation, right: RunContinuation): Bool {
    sameContinuationRequestBinding(left, right) &&
        approvalRequestBindingsEqual(left.approval, right.approval) &&
        sameRunningCheckpoint(left.runningModel, right.runningModel)
}

func sameContinuationRequestBinding(left: RunContinuation, right: RunContinuation): Bool {
    left.kind == right.kind &&
        left.runId.value == right.runId.value && left.sessionId.value == right.sessionId.value &&
        left.model == right.model && left.prompt == right.prompt && left.system == right.system &&
        left.thinking == right.thinking && left.approvalMode == right.approvalMode &&
        left.autoRetry == right.autoRetry && left.serviceTier == right.serviceTier &&
        left.cachePolicy == right.cachePolicy &&
        left.cacheKey == right.cacheKey &&
        left.parallelToolCalls == right.parallelToolCalls &&
        structuredOutputSpecsEqual(left.structuredOutput, right.structuredOutput) &&
        capabilitySetsEqual(left.capabilities, right.capabilities) &&
        resourceBudgetsEqual(left.budget, right.budget) &&
        modelPricingEqual(left.pricing, right.pricing) &&
        left.resolverVersion == right.resolverVersion &&
        left.contextWindow == right.contextWindow &&
        left.providerSafetyMargin == right.providerSafetyMargin &&
        agentValuesEqual(left.skillStackPayload, right.skillStackPayload) &&
        agentValuesEqual(left.toolContextPayload, right.toolContextPayload) &&
        sameRequestedPolicy(left.requestedPolicy, right.requestedPolicy) &&
        sameCapabilitiesSnapshot(
            left.modelCapabilitiesSnapshot, right.modelCapabilitiesSnapshot
        )
}

func approvedContinuationTransition(
    previous: RunContinuation,
    next: RunContinuation,
    decision: ?ApprovalDecisionReceipt
): Bool {
    if (previous.kind != RunContinuationKind.WaitingApproval ||
        next.kind != RunContinuationKind.WaitingApproval) {
        return false
    }
    match (decision) {
        case Some(receipt) =>
            continuationAcceptsDecision(previous, receipt) &&
                sameContinuationRequestBinding(previous, next)
        case None => false
    }
}

func sameRequestedPolicy(
    left: ?RequestedModelPolicy,
    right: ?RequestedModelPolicy
): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) =>
            a.policyRequestedThinking == b.policyRequestedThinking &&
                a.userRequestedThinking == b.userRequestedThinking &&
                a.thinkingSource == b.thinkingSource &&
                a.requestOutputBudget.hardLimit == b.requestOutputBudget.hardLimit &&
                a.requestOutputBudget.minVisibleResponseTokens ==
                    b.requestOutputBudget.minVisibleResponseTokens
        case _ => false
    }
}

func sameCapabilitiesSnapshot(
    left: ?ModelExecutionCapabilitiesSnapshot,
    right: ?ModelExecutionCapabilitiesSnapshot
): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) =>
            a.snapshotSchemaVersion == b.snapshotSchemaVersion &&
                a.capabilityFingerprint == b.capabilityFingerprint
        case _ => false
    }
}

func sameRunningCheckpoint(
    left: ?RunningModelCheckpoint,
    right: ?RunningModelCheckpoint
): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) =>
            a.semanticRequestId.value == b.semanticRequestId.value &&
                a.semanticRequestDigest == b.semanticRequestDigest &&
                a.wirePolicyDigest == b.wirePolicyDigest &&
                a.originalAttemptId.value == b.originalAttemptId.value &&
                a.activeAttemptId.value == b.activeAttemptId.value &&
                a.stableTurnId == b.stableTurnId &&
                a.stableRequestId == b.stableRequestId &&
                agentValuesEqual(a.canonicalRequest, b.canonicalRequest)
        case _ => false
    }
}

// -1 is invalid/drift, 0 is an exact idempotent event, 1 may append.
func memoryEventAppendDisposition(
    values: ArrayList<AgentEvent>,
    event: AgentEvent
): Int64 {
    for (existing in values where existing.sequence == event.sequence) {
        return if (existing.runId.value == event.runId.value &&
            existing.kind == event.kind &&
            agentValuesEqual(existing.detail, event.detail)) { 0 } else { -1 }
    }
    let expected = if (values.isEmpty()) { 1 } else {
        values[values.size - 1].sequence + 1
    }
    if (event.sequence == expected) { 1 } else { -1 }
}

func sameOptionalContinuation(left: ?RunContinuation, right: ?RunContinuation): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) => sameContinuationBinding(a, b)
        case _ => false
    }
}

func sameMemoryAttempt(left: DurableModelAttempt, right: DurableModelAttempt): Bool {
    left.id.value == right.id.value &&
        left.semanticRequestId.value == right.semanticRequestId.value &&
        left.runId.value == right.runId.value && left.attemptNo == right.attemptNo &&
        left.providerRequestId == right.providerRequestId &&
        left.semanticRequestDigest == right.semanticRequestDigest &&
        left.wirePolicyDigest == right.wirePolicyDigest &&
        agentValuesEqual(left.policy, right.policy)
}

func copyMemoryAttemptDispatch(
    value: DurableModelAttempt,
    dispatchStartedAtMillis: Int64
): DurableModelAttempt {
    DurableModelAttempt(
        value.id, value.semanticRequestId, value.runId, value.attemptNo,
        value.lifecycle, value.policy, value.policyReason,
        value.startedAtMillis, value.lastActivityAtMillis,
        parentAttemptId: value.parentAttemptId,
        completedAtMillis: value.completedAtMillis,
        providerRequestId: value.providerRequestId,
        providerResponseId: value.providerResponseId,
        failureKind: value.failureKind,
        semanticRequestDigest: value.semanticRequestDigest,
        wirePolicyDigest: value.wirePolicyDigest,
        dispatchState: ModelAttemptDispatchState.DispatchClaimed,
        replayBarrier: value.replayBarrier,
        dispatchStartedAtMillis: Some(dispatchStartedAtMillis),
        providerTerminalAtMillis: value.providerTerminalAtMillis
    )
}

func copyMemoryAttemptBarrier(
    value: DurableModelAttempt,
    barrier: ModelAttemptReplayBarrier
): DurableModelAttempt {
    DurableModelAttempt(
        value.id, value.semanticRequestId, value.runId, value.attemptNo,
        value.lifecycle, value.policy, value.policyReason,
        value.startedAtMillis, value.lastActivityAtMillis,
        parentAttemptId: value.parentAttemptId,
        completedAtMillis: value.completedAtMillis,
        providerRequestId: value.providerRequestId,
        providerResponseId: value.providerResponseId,
        failureKind: value.failureKind,
        semanticRequestDigest: value.semanticRequestDigest,
        wirePolicyDigest: value.wirePolicyDigest,
        dispatchState: value.dispatchState,
        replayBarrier: barrier,
        dispatchStartedAtMillis: value.dispatchStartedAtMillis,
        providerTerminalAtMillis: if (barrier == ModelAttemptReplayBarrier.ProviderTerminal) {
            Some(agentUtcMillis())
        } else { value.providerTerminalAtMillis }
    )
}

func copyMemoryAttemptAbandoned(
    value: DurableModelAttempt,
    completedAtMillis: Int64
): DurableModelAttempt {
    DurableModelAttempt(
        value.id, value.semanticRequestId, value.runId, value.attemptNo,
        ModelAttemptLifecycle.Abandoned, value.policy, value.policyReason,
        value.startedAtMillis, completedAtMillis,
        parentAttemptId: value.parentAttemptId,
        completedAtMillis: Some(completedAtMillis),
        providerRequestId: value.providerRequestId,
        providerResponseId: value.providerResponseId,
        failureKind: "process_restart_possible_duplicate",
        semanticRequestDigest: value.semanticRequestDigest,
        wirePolicyDigest: value.wirePolicyDigest,
        dispatchState: value.dispatchState,
        replayBarrier: value.replayBarrier,
        dispatchStartedAtMillis: value.dispatchStartedAtMillis,
        providerTerminalAtMillis: value.providerTerminalAtMillis
    )
}

func structuredOutputSpecsEqual(
    left: ?StructuredOutputSpec,
    right: ?StructuredOutputSpec
): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) =>
            a.name == b.name && a.description == b.description &&
                a.strict == b.strict && agentValuesEqual(a.schema, b.schema)
        case _ => false
    }
}

func continuationAcceptsDecision(
    continuation: RunContinuation,
    receipt: ApprovalDecisionReceipt
): Bool {
    continuation.runId.value == receipt.runId.value &&
        continuation.sessionId.value == receipt.sessionId.value &&
        continuation.approval.operationId.value == receipt.operationId.value &&
        continuation.approval.callId == receipt.callId &&
        continuation.approval.sessionId == receipt.sessionId.value &&
        continuation.approval.argumentHash == receipt.argumentHash
}

func capabilitySetsEqual(left: CapabilitySet, right: CapabilitySet): Bool {
    if (left.values.size != right.values.size) { return false }
    for (index in 0..left.values.size) {
        if (left.values[index].kind != right.values[index].kind ||
            left.values[index].resource != right.values[index].resource) { return false }
    }
    true
}

func resourceBudgetsEqual(left: ResourceBudget, right: ResourceBudget): Bool {
        left.maxInputTokens == right.maxInputTokens &&
        left.maxOutputTokens == right.maxOutputTokens &&
        left.requestOutputBudget.minVisibleResponseTokens ==
            right.requestOutputBudget.minVisibleResponseTokens &&
        left.maxTotalInputTokens == right.maxTotalInputTokens &&
        left.maxTotalOutputTokens == right.maxTotalOutputTokens &&
        left.maxModelRequests == right.maxModelRequests &&
        left.maxTurns == right.maxTurns && left.maxToolCalls == right.maxToolCalls &&
        left.maxWallMillis == right.maxWallMillis && left.maxIdleMillis == right.maxIdleMillis &&
        left.maxChildren == right.maxChildren && left.maxDepth == right.maxDepth &&
        left.maxConcurrentChildren == right.maxConcurrentChildren &&
        left.maxContextMessages == right.maxContextMessages &&
        left.maxConcurrentTools == right.maxConcurrentTools &&
    left.maxCostMicros == right.maxCostMicros &&
        left.deadlineMillis == right.deadlineMillis
}

func modelPricingEqual(left: ?ModelPricing, right: ?ModelPricing): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) =>
            a.inputMicrosPerMillion == b.inputMicrosPerMillion &&
                a.outputMicrosPerMillion == b.outputMicrosPerMillion &&
                a.cacheReadMicrosPerMillion == b.cacheReadMicrosPerMillion &&
                a.cacheWriteMicrosPerMillion == b.cacheWriteMicrosPerMillion
        case _ => false
    }
}

func approvalRequestsEqual(left: ApprovalRequest, right: ApprovalRequest): Bool {
    left.operationId.value == right.operationId.value && left.callId == right.callId &&
        left.toolName == right.toolName && left.capability.kind == right.capability.kind &&
        left.capability.resource == right.capability.resource &&
        agentValuesEqual(left.preview, right.preview) && left.sessionId == right.sessionId &&
        left.argumentHash == right.argumentHash && stringArraysEqual(left.riskFlags, right.riskFlags) &&
        left.decisionSource == right.decisionSource
}

func approvalRequestBindingsEqual(left: ApprovalRequest, right: ApprovalRequest): Bool {
    left.operationId.value == right.operationId.value &&
        left.sessionId == right.sessionId && left.callId == right.callId &&
        left.argumentHash == right.argumentHash
}

func stringArraysEqual(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) { return false }
    for (index in 0..left.size) {
        if (left[index] != right[index]) { return false }
    }
    true
}

func sameDecisionBinding(
    left: ApprovalDecisionReceipt,
    right: ApprovalDecisionReceipt
): Bool {
    left.operationId.value == right.operationId.value &&
        left.runId.value == right.runId.value &&
        left.sessionId.value == right.sessionId.value &&
        left.callId == right.callId && left.argumentHash == right.argumentHash &&
        left.decision == right.decision
}

func invalidReceiptBinding<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "conversation.receipt_binding_invalid",
        message
    ))
}

func memoryRecoveryRequired<T>(runId: String, message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired,
        "run.continuation_recovery_required",
        message,
        fields: [ErrorField("run_id", runId)]
    ))
}

func missingMemoryValue<T>(kind: String, id: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "testkit.memory_not_found",
        kind + " not found: " + id
    ))
}

func memoryConflict<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Conflict,
        "testkit.memory_conflict",
        message
    ))
}
