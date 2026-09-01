package sdk_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.sync.*
import tool_runtime.*

class FakeRunEntry {
    var snapshot: RunSnapshot
    let events = ArrayList<AgentEvent>()
    let attempts = ArrayList<DurableModelAttempt>()
    var continuation: ?RunContinuation = None

    init(snapshot: RunSnapshot) {
        this.snapshot = snapshot
    }
}

class FakeRunStore <: RunRepository {
    private let lock = Mutex()
    private let entries = ArrayList<FakeRunEntry>()
    private var decisionValue: ?ApprovalDecisionReceipt = None

    public func save(snapshot: RunSnapshot): Result<Unit> {
        lock.lock()
        try {
            match (findEntry(snapshot.runId.value)) {
                case Some(value) => value.snapshot = snapshot
                case None => entries.add(FakeRunEntry(snapshot))
            }
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        lock.lock()
        try {
            match (findEntry(runId.value)) {
                case Some(value) => Result.Ok(value.snapshot)
                case None => missing<RunSnapshot>("run", runId.value)
            }
        } finally {
            lock.unlock()
        }
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        lock.lock()
        try {
            let entry = match (findEntry(runId.value)) {
                case Some(value) => value
                case None => return missing<EventPage>("run", runId.value)
            }
            let values = ArrayList<AgentEvent>()
            var next = after + 1
            for (event in entry.events where event.sequence > after) {
                values.add(event)
                next = event.sequence + 1
            }
            Result.Ok(EventPage(values.toArray(), next))
        } finally {
            lock.unlock()
        }
    }

    public func append(event: AgentEvent): Result<Unit> {
        lock.lock()
        try {
            let entry = match (findEntry(event.runId.value)) {
                case Some(value) => value
                case None => return missing<Unit>("run", event.runId.value)
            }
            entry.events.add(event)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func saveContinuation(value: RunContinuation): Result<Unit> {
        lock.lock()
        try {
            match (findEntry(value.runId.value)) {
                case Some(entry) =>
                    entry.continuation = Some(value)
                    Result.Ok(())
                case None => missing<Unit>("run", value.runId.value)
            }
        } finally {
            lock.unlock()
        }
    }

    public func continuation(runId: RunId): Result<RunContinuation> {
        lock.lock()
        try {
            match (findEntry(runId.value)) {
                case Some(entry) => match (entry.continuation) {
                    case Some(value) => Result.Ok(value)
                    case None => missing<RunContinuation>("continuation", runId.value)
                }
                case None => missing<RunContinuation>("run", runId.value)
            }
        } finally {
            lock.unlock()
        }
    }

    public func pendingContinuation(sessionId: SessionId): Result<?RunContinuation> {
        lock.lock()
        try {
            for (entry in entries where entry.snapshot.sessionId.value == sessionId.value &&
                 entry.snapshot.status == RunState.WaitingApproval) {
                return Result.Ok(entry.continuation)
            }
            Result.Ok(None)
        } finally {
            lock.unlock()
        }
    }

    public func pendingRecoveryContinuation(sessionId: SessionId): Result<?RunContinuation> {
        lock.lock()
        try {
            for (entry in entries where entry.snapshot.sessionId.value == sessionId.value) {
                match (entry.continuation) {
                    case Some(value) => if (value.kind == RunContinuationKind.RunningModel) {
                        return Result.Ok(Some(value))
                    }
                    case None => ()
                }
            }
            Result.Ok(None)
        } finally { lock.unlock() }
    }

    public func prepareModelAttempt(
        attempt: DurableModelAttempt,
        event: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        lock.lock()
        try {
            let entry = match (findEntry(attempt.runId.value)) {
                case Some(value) => value
                case None => return missing<Unit>("run", attempt.runId.value)
            }
            for (existing in entry.attempts where existing.id.value == attempt.id.value) {
                return if (sameFakeAttempt(existing, attempt)) { Result.Ok(()) } else {
                    conflict<Unit>("model Attempt identity drift")
                }
            }
            entry.attempts.add(attempt)
            entry.continuation = Some(continuation)
            entry.events.add(event)
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func modelAttempt(attemptId: ModelAttemptId): Result<DurableModelAttempt> {
        lock.lock()
        try {
            for (entry in entries) {
                for (attempt in entry.attempts where attempt.id.value == attemptId.value) {
                    return Result.Ok(attempt)
                }
            }
            missing<DurableModelAttempt>("model_attempt", attemptId.value)
        } finally { lock.unlock() }
    }

    public func claimModelAttemptDispatch(
        attemptId: ModelAttemptId,
        event: AgentEvent
    ): Result<Bool> {
        lock.lock()
        try {
            let entry = match (findEntry(event.runId.value)) {
                case Some(value) => value
                case None => return missing<Bool>("run", event.runId.value)
            }
            for (index in 0..entry.attempts.size where entry.attempts[index].id.value == attemptId.value) {
                let attempt = entry.attempts[index]
                if (attempt.dispatchState == ModelAttemptDispatchState.DispatchClaimed) {
                    return Result.Ok(false)
                }
                if (attempt.dispatchState != ModelAttemptDispatchState.Prepared) {
                    return conflict<Bool>("model Attempt is not dispatchable")
                }
                entry.attempts[index] = fakeAttemptWithDispatch(attempt, event.meta.occurredAtMillis)
                entry.events.add(event)
                return Result.Ok(true)
            }
            missing<Bool>("model_attempt", attemptId.value)
        } finally { lock.unlock() }
    }

    public func markModelAttemptReplayBarrier(
        attemptId: ModelAttemptId,
        barrier: ModelAttemptReplayBarrier,
        event: AgentEvent
    ): Result<Unit> {
        lock.lock()
        try {
            let entry = match (findEntry(event.runId.value)) {
                case Some(value) => value
                case None => return missing<Unit>("run", event.runId.value)
            }
            for (index in 0..entry.attempts.size where entry.attempts[index].id.value == attemptId.value) {
                let attempt = entry.attempts[index]
                if (attempt.replayBarrier == barrier) { return Result.Ok(()) }
                if (attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
                    return conflict<Unit>("model replay barrier identity drift")
                }
                entry.attempts[index] = fakeAttemptWithBarrier(attempt, barrier, event.meta.occurredAtMillis)
                entry.events.add(event)
                return Result.Ok(())
            }
            missing<Unit>("model_attempt", attemptId.value)
        } finally { lock.unlock() }
    }

    public func clearModelExecutionContinuation(
        runId: RunId,
        activeAttemptId: ModelAttemptId
    ): Result<Unit> {
        lock.lock()
        try {
            let entry = match (findEntry(runId.value)) {
                case Some(value) => value
                case None => return missing<Unit>("run", runId.value)
            }
            match (entry.continuation) {
                case Some(value) => match (value.runningModel) {
                    case Some(checkpoint) => if (checkpoint.activeAttemptId.value != activeAttemptId.value) {
                        return conflict<Unit>("model continuation Attempt binding drift")
                    }
                    case None => return conflict<Unit>("continuation is not a model execution")
                }
                case None => return Result.Ok(())
            }
            entry.continuation = None
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func saveDecision(receipt: ApprovalDecisionReceipt): Result<Unit> {
        lock.lock()
        try {
            decisionValue = Some(receipt)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func decision(operationId: OperationId): Result<ApprovalDecisionReceipt> {
        lock.lock()
        try {
            match (decisionValue) {
                case Some(value) => if (value.operationId.value == operationId.value) {
                    Result.Ok(value)
                } else {
                    missing<ApprovalDecisionReceipt>("decision", operationId.value)
                }
                case None => missing<ApprovalDecisionReceipt>("decision", operationId.value)
            }
        } finally {
            lock.unlock()
        }
    }

    public func recordDecision(receipt: ApprovalDecisionReceipt): Result<RunSnapshot> {
        lock.lock()
        try {
            let entry = match (findEntry(receipt.runId.value)) {
                case Some(value) => value
                case None => return missing<RunSnapshot>("run", receipt.runId.value)
            }
            if (entry.snapshot.status != RunState.WaitingApproval &&
                entry.snapshot.status != RunState.Completed) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.not_awaiting_approval",
                    "run is not awaiting approval"
                ))
            }
            match (decisionValue) {
                case Some(value) =>
                    if (value.operationId.value != receipt.operationId.value || value.callId != receipt.callId) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "run.decision_conflict",
                            "approval decision is already bound"
                        ))
                    }
                case None => decisionValue = Some(receipt)
            }
            Result.Ok(entry.snapshot)
        } finally {
            lock.unlock()
        }
    }

    private func findEntry(runId: String): ?FakeRunEntry {
        for (entry in entries where entry.snapshot.runId.value == runId) { return Some(entry) }
        None
    }
}

func sameFakeAttempt(left: DurableModelAttempt, right: DurableModelAttempt): Bool {
    left.id.value == right.id.value && left.semanticRequestId.value == right.semanticRequestId.value &&
        left.runId.value == right.runId.value && left.attemptNo == right.attemptNo &&
        left.semanticRequestDigest == right.semanticRequestDigest &&
        left.wirePolicyDigest == right.wirePolicyDigest
}

func fakeAttemptWithDispatch(value: DurableModelAttempt, at: Int64): DurableModelAttempt {
    copyFakeAttempt(
        value,
        ModelAttemptDispatchState.DispatchClaimed,
        value.replayBarrier,
        Some(at),
        value.providerTerminalAtMillis
    )
}

func fakeAttemptWithBarrier(
    value: DurableModelAttempt,
    barrier: ModelAttemptReplayBarrier,
    at: Int64
): DurableModelAttempt {
    copyFakeAttempt(
        value,
        value.dispatchState,
        barrier,
        value.dispatchStartedAtMillis,
        if (barrier == ModelAttemptReplayBarrier.ProviderTerminal) {
            Some(at)
        } else { value.providerTerminalAtMillis }
    )
}

func copyFakeAttempt(
    value: DurableModelAttempt,
    dispatchState: ModelAttemptDispatchState,
    replayBarrier: ModelAttemptReplayBarrier,
    dispatchStartedAtMillis: ?Int64,
    providerTerminalAtMillis: ?Int64
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
        dispatchState: dispatchState,
        replayBarrier: replayBarrier,
        dispatchStartedAtMillis: dispatchStartedAtMillis,
        providerTerminalAtMillis: providerTerminalAtMillis
    )
}

class FakeOperationEntry {
    var record: OperationRecord
    var receiptValue: ?OperationReceipt = None

    init(record: OperationRecord) {
        this.record = record
    }
}

class FakeOperationStore <: OperationRepository {
    private let entries = ArrayList<FakeOperationEntry>()

    public func prepare(record: OperationRecord): Result<Unit> {
        match (entry(record.operationId.value)) {
            case Some(existing) => if (existing.record.requestDigest == record.requestDigest) {
                Result.Ok(())
            } else {
                conflict<Unit>("operation digest changed")
            }
            case None =>
                entries.add(FakeOperationEntry(record))
                Result.Ok(())
        }
    }

    public func transition(
        operationId: OperationId,
        expected: OperationStatus,
        next: OperationStatus
    ): Result<Unit> {
        let value = match (entry(operationId.value)) {
            case Some(item) => item
            case None => return missing<Unit>("operation", operationId.value)
        }
        if (value.record.status != expected) {
            return conflict<Unit>("operation state changed")
        }
        let current = value.record
        value.record = OperationRecord(
            current.operationId,
            current.runId,
            next,
            current.capability,
            current.requestDigest,
            call: current.call
        )
        Result.Ok(())
    }

    public func find(operationId: OperationId): Result<OperationRecord> {
        match (entry(operationId.value)) {
            case Some(value) => Result.Ok(value.record)
            case None => missing<OperationRecord>("operation", operationId.value)
        }
    }

    public func receipt(operationId: OperationId): Result<OperationReceipt> {
        match (entry(operationId.value)) {
            case Some(value) => match (value.receiptValue) {
                case Some(receipt) => Result.Ok(receipt)
                case None => missing<OperationReceipt>("receipt", operationId.value)
            }
            case None => missing<OperationReceipt>("operation", operationId.value)
        }
    }

    public func saveReceipt(receipt: OperationReceipt): Result<Unit> {
        match (entry(receipt.operationId.value)) {
            case Some(value) =>
                value.receiptValue = Some(receipt)
                Result.Ok(())
            case None => missing<Unit>("operation", receipt.operationId.value)
        }
    }

    private func entry(id: String): ?FakeOperationEntry {
        for (value in entries where value.record.operationId.value == id) { return Some(value) }
        None
    }
}

class FakeAudit <: AuditPort {
    let events = ArrayList<AgentEvent>()
    public func append(event: AgentEvent): Result<Unit> {
        events.add(event)
        Result.Ok(())
    }
}

class FakeIds <: IdGenerator {
    private var run: Int64 = 0
    private var session: Int64 = 0
    private var operation: Int64 = 0

    public func nextRunId(): RunId {
        run += 1
        RunId("sdk-run-" + run.toString())
    }

    public func nextSessionId(): SessionId {
        session += 1
        SessionId("sdk-session-" + session.toString())
    }

    public func nextOperationId(): OperationId {
        operation += 1
        OperationId("sdk-operation-" + operation.toString())
    }
}

class TextProvider <: ModelPort {
    let text: String
    var calls: Int64 = 0
    var lastModel: String = ""
    var lastSystem: String = ""

    init(text: String) {
        this.text = text
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        lastModel = request.model
        lastSystem = request.system
        events(ModelEvent.TextDelta(text))
        events(ModelEvent.UsageUpdated(8, 2))
        events(ModelEvent.Completed)
        Result.Ok(ModelReply(
            [ModelBlock(ModelBlockKind.Text, text: text)],
            stopReason: "stop",
            inputTokens: 8,
            outputTokens: 2,
            terminalEvidence: Some(sdkTerminalEvidence("stop")),
            completionDisposition: CompletionDisposition.Complete,
            decisionOutcome: DecisionOutcome.Response,
            validationVersion: 1
        ))
    }
}

class StructuredVisionProvider <: ModelPort {
    private let value: AgentValue
    var sawImage: Bool = false
    var sawStructuredOutput: Bool = false
    var sawStablePrefixCache: Bool = false
    var sawParallelToolCalls: Bool = false
    var cacheKey: String = ""

    init(value: AgentValue) {
        this.value = value
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        for (message in request.messages) {
            for (block in message.blocks) {
                match (block.kind) {
                    case ModelBlockKind.Image => sawImage = block.image.isSome()
                    case _ => ()
                }
            }
        }
        sawStructuredOutput = request.structuredOutput.isSome()
        sawParallelToolCalls = request.parallelToolCalls
        sawStablePrefixCache = match (request.cachePolicy) {
            case ModelCachePolicy.StablePrefix => true
            case _ => false
        }
        cacheKey = request.cacheKey
        events(ModelEvent.TextDelta("{\"answer\":\"typed SDK result\"}"))
        events(ModelEvent.Completed)
        Result.Ok(ModelReply(
            [ModelBlock(
                ModelBlockKind.Text,
                text: "{\"answer\":\"typed SDK result\"}"
            )],
            stopReason: "stop",
            inputTokens: 8,
            outputTokens: 4,
            structuredOutput: Some(value),
            terminalEvidence: Some(sdkTerminalEvidence("stop")),
            completionDisposition: CompletionDisposition.Complete,
            decisionOutcome: DecisionOutcome.Response,
            validationVersion: 1
        ))
    }
}

class SuccessThenFailureProvider <: ModelPort {
    private let firstText: String
    private var calls: Int64 = 0

    init(firstText: String) {
        this.firstText = firstText
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        calls += 1
        if (calls == 1) {
            // Deliberately omit TextDelta. Headless mode must recover this
            // invocation's final assistant message from the transcript.
            events(ModelEvent.Completed)
            return Result.Ok(ModelReply(
                [ModelBlock(ModelBlockKind.Text, text: firstText)],
                stopReason: "stop",
                inputTokens: 4,
                outputTokens: 2,
                terminalEvidence: Some(sdkTerminalEvidence("stop")),
                completionDisposition: CompletionDisposition.Complete,
                decisionOutcome: DecisionOutcome.Response,
                validationVersion: 1
            ))
        }
        Result.Err(AgentError(
            AgentErrorKind.Provider,
            "contract.second_run_failed",
            "the second run fails without assistant output"
        ))
    }
}

class ApprovalProvider <: ModelPort {
    var calls: Int64 = 0

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        calls += 1
        if (calls == 1) {
            events(ModelEvent.ToolCallStarted("call-approval", "write_demo"))
            events(ModelEvent.ToolArgumentsDelta("call-approval", "{}"))
            events(ModelEvent.ToolCallCompleted("call-approval"))
            events(ModelEvent.Completed)
            return Result.Ok(ModelReply(
                [ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "call-approval",
                    name: "write_demo",
                    arguments: objectValue([])
                )],
                stopReason: "tool_use",
                inputTokens: 8,
                outputTokens: 2,
                terminalEvidence: Some(sdkTerminalEvidence("tool_use")),
                completionDisposition: CompletionDisposition.ToolUse,
                decisionOutcome: DecisionOutcome.ToolCalls,
                validationVersion: 1
            ))
        }
        events(ModelEvent.TextDelta("approved"))
        events(ModelEvent.Completed)
        Result.Ok(ModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "approved")],
            stopReason: "stop",
            inputTokens: 8,
            outputTokens: 2,
            terminalEvidence: Some(sdkTerminalEvidence("stop")),
            completionDisposition: CompletionDisposition.Complete,
            decisionOutcome: DecisionOutcome.Response,
            validationVersion: 1
        ))
    }
}

class ToolContextProvider <: ModelPort {
    var calls: Int64 = 0

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        calls += 1
        if (calls == 1) {
            events(ModelEvent.ToolCallStarted("context-call", "context_probe"))
            events(ModelEvent.ToolCallCompleted("context-call"))
            events(ModelEvent.Completed)
            return Result.Ok(ModelReply(
                [ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "context-call",
                    name: "context_probe",
                    arguments: objectValue([])
                )],
                stopReason: "tool_use",
                inputTokens: 4,
                outputTokens: 1,
                terminalEvidence: Some(sdkTerminalEvidence("tool_use")),
                completionDisposition: CompletionDisposition.ToolUse,
                decisionOutcome: DecisionOutcome.ToolCalls,
                validationVersion: 1
            ))
        }
        events(ModelEvent.TextDelta("context captured"))
        events(ModelEvent.Completed)
        Result.Ok(ModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "context captured")],
            stopReason: "stop",
            inputTokens: 4,
            outputTokens: 2,
            terminalEvidence: Some(sdkTerminalEvidence("stop")),
            completionDisposition: CompletionDisposition.Complete,
            decisionOutcome: DecisionOutcome.Response,
            validationVersion: 1
        ))
    }
}

class LoopingToolProvider <: ModelPort {
    var calls: Int64 = 0

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        calls += 1
        let id = "loop-call-" + calls.toString()
        events(ModelEvent.ToolCallStarted(id, "read_demo"))
        events(ModelEvent.ToolCallCompleted(id))
        events(ModelEvent.Completed)
        Result.Ok(ModelReply(
            [ModelBlock(
                ModelBlockKind.ToolCall,
                callId: id,
                name: "read_demo",
                arguments: objectValue([])
            )],
            stopReason: "tool_use",
            inputTokens: 4,
            outputTokens: 1,
            terminalEvidence: Some(sdkTerminalEvidence("tool_use")),
            completionDisposition: CompletionDisposition.ToolUse,
            decisionOutcome: DecisionOutcome.ToolCalls,
            validationVersion: 1
        ))
    }
}

func sdkTerminalEvidence(stopReason: String): TerminalEvidence {
    TerminalEvidence(
        "fixture", "message_stop", rawStopReason: stopReason,
        messageTerminalObserved: true, streamEofObserved: true,
        adapterVersion: "sdk-contract-v1"
    )
}

class SelfCancellingProvider <: ModelPort {
    let source: CancellationSource
    var executeCalls: Int64 = 0
    var cancelCalls: Int64 = 0

    init(source: CancellationSource) {
        this.source = source
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        let _ = events
        executeCalls += 1
        source.cancel(reason: Some(CancellationReason(
            CancellationReasonKind.User,
            "contract.cancelled",
            "contract requested cancellation"
        )))
        Result.Err(AgentError(
            AgentErrorKind.Cancelled,
            "contract.cancelled",
            "contract requested cancellation"
        ))
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        cancelCalls += 1
        Result.Ok(())
    }
}

class BlockingCancellationProbe {
    private let gateLock = Mutex()
    private var entered: Bool = false

    func armCancellationRead(): Unit {
        gateLock.lock()
        try { entered = true } finally { gateLock.unlock() }
    }

    func cancellationReadEntered(): Bool {
        gateLock.lock()
        try { entered } finally { gateLock.unlock() }
    }

    func releaseCancellationRead(): Unit {}
}
class BlockingCancellationProvider <: ModelPort {
    private let source: CancellationSource
    private let conversations: BlockingCancellationProbe

    init(
        source: CancellationSource,
        conversations: BlockingCancellationProbe
    ) {
        this.source = source
        this.conversations = conversations
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        let _ = events
        conversations.armCancellationRead()
        source.cancel(reason: Some(CancellationReason(
            CancellationReasonKind.User,
            "contract.blocking_cancel",
            "preserve this cancellation reason"
        )))
        var waited: Int64 = 0
        while (!conversations.cancellationReadEntered() && waited < 2000) {
            sleep(Duration.millisecond)
            waited += 1
        }
        Result.Err(AgentError(
            AgentErrorKind.Cancelled,
            "provider.generic_cancel",
            "provider cancellation should be replaced with the source reason"
        ))
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        Result.Ok(())
    }
}

class DemoTool <: ToolExecutor {
    var calls: Int64 = 0
    public func execute(context: ToolInvocationContext, call: ToolCall): Result<ToolResult> {
        let _ = context
        calls += 1
        Result.Ok(ToolResult(call.callId, objectValue([ValueField("ok", boolValue(true))])))
    }
}

class ToolContextCaptureTool <: ToolExecutor {
    var calls: Int64 = 0
    var valid = false

    public func execute(context: ToolInvocationContext, call: ToolCall): Result<ToolResult> {
        calls += 1
        valid = context.workspaceRoot == "/sdk/explicit-workspace" &&
            context.cwd == "/sdk/explicit-workspace/src" &&
            context.environment.value("SDK_VISIBLE") == Some("sdk-private-value") &&
            context.environment.names().size == 1 &&
            context.services.contains(ToolServiceKind.Custom, name: "sdk-context-service") &&
            !context.cancellation.isCancelled()
        Result.Ok(ToolResult(call.callId, objectValue([ValueField("valid", boolValue(valid))])))
    }
}

func missing<T>(kind: String, id: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "fake.not_found",
        kind + " not found: " + id
    ))
}

func conflict<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, "fake.conflict", message))
}
