package agent_domain

import std.deriving.*

public class SemanticModelRequestId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("semantic model request", value)
    }
}

public class ModelAttemptId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("model attempt", value)
    }
}

public class ModelDecisionId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("model decision", value)
    }
}

public class DecisionBlockId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("decision block", value)
    }
}

public class ScopedToolCallId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("scoped tool call", value)
    }
}

@Derive[Equatable]
public enum ModelAttemptLifecycle {
    Created | Streaming | Completed | Failed | Cancelled | Abandoned
}

@Derive[Equatable]
public enum ModelAttemptDispatchState {
    Prepared | DispatchClaimed
}

@Derive[Equatable]
public enum ModelAttemptReplayBarrier {
    NoBarrier | ToolEvidence | ProviderTerminal | Cancelled | RunDeadline
}

@Derive[Equatable]
public enum DecisionValidationStatus {
    Candidate | Validated | Rejected
}

@Derive[Equatable]
public enum CompletionDisposition {
    Complete | ToolUse | OutputLimited | Filtered | ProtocolIncomplete | Unknown
}

@Derive[Equatable]
public enum DecisionOutcome {
    Response | ToolCalls | Refusal | Unknown
}

@Derive[Equatable]
public enum AttemptPolicyReason {
    Initial | Retry | DeadlineEscalation | OutputLimitRecovery
}

@Derive[Equatable]
public enum AttemptFailureKind {
    ConnectTimeout
    | FirstResponseTimeout
    | StreamIdleTimeout
    | AttemptSoftDeadlineExceeded
    | AttemptHardDeadlineExceeded
    | DecisionIncompleteAtDeadline
    | ProviderTerminalMissing
    | ProtocolIncomplete
    | OutputLimited
    | OutputLimitedBeforeDecision
    | ProviderTransportError
    | ProviderProtocolError
    | UserCancelled
    | RunDeadlineExceeded
}

@Derive[Equatable]
public enum AttemptProgressKind {
    NoProgress
    | ReasoningProgress
    | TextProgress
    | ToolCallStartedProgress
    | ToolArgumentProgress
    | ContentBlockCompletedProgress
    | ProviderTerminalProgress
}

public class AttemptFailureDiagnostics {
    public let elapsedMillis: Int64
    public let softDeadlineMillis: Int64
    public let hardDeadlineMillis: Int64
    public let enteredCompletionGrace: Bool
    public let lastProgressKind: AttemptProgressKind
    public let lastProgressAgeMillis: Int64
    public let providerTerminalObserved: Bool
    public let openContentBlockCount: Int64
    public let toolCallsStarted: Int64
    public let toolCallsCompleted: Int64

    public init(
        elapsedMillis!: Int64 = 0,
        softDeadlineMillis!: Int64 = 0,
        hardDeadlineMillis!: Int64 = 0,
        enteredCompletionGrace!: Bool = false,
        lastProgressKind!: AttemptProgressKind = AttemptProgressKind.NoProgress,
        lastProgressAgeMillis!: Int64 = 0,
        providerTerminalObserved!: Bool = false,
        openContentBlockCount!: Int64 = 0,
        toolCallsStarted!: Int64 = 0,
        toolCallsCompleted!: Int64 = 0
    ) {
        this.elapsedMillis = max(0, elapsedMillis)
        this.softDeadlineMillis = max(0, softDeadlineMillis)
        this.hardDeadlineMillis = max(0, hardDeadlineMillis)
        this.enteredCompletionGrace = enteredCompletionGrace
        this.lastProgressKind = lastProgressKind
        this.lastProgressAgeMillis = max(0, lastProgressAgeMillis)
        this.providerTerminalObserved = providerTerminalObserved
        this.openContentBlockCount = max(0, openContentBlockCount)
        this.toolCallsStarted = max(0, toolCallsStarted)
        this.toolCallsCompleted = max(0, toolCallsCompleted)
    }
}

public class AttemptFailure {
    public let kind: AttemptFailureKind
    public let diagnostics: AttemptFailureDiagnostics
    public init(kind: AttemptFailureKind, diagnostics!: AttemptFailureDiagnostics = AttemptFailureDiagnostics()) {
        this.kind = kind
        this.diagnostics = diagnostics
    }
}

// The effective provider controls for one wire attempt. This is deliberately
// separate from the semantic request: retries may receive another policy, but
// every applied policy is durable and auditable before the wire request starts.
public class AttemptPolicy {
    public let model: String
    public let thinking: ThinkingLevel
    public let toolChoice: ModelToolChoice
    public let maxOutputTokens: Int64
    public let reason: AttemptPolicyReason
    public let softDeadlineMillis: Int64
    public let hardDeadlineMillis: Int64
    public let streamIdleMillis: Int64
    public let resolvedPolicy: ?ResolvedModelRequestPolicy

    public init(
        model: String,
        thinking: ThinkingLevel,
        toolChoice: ModelToolChoice,
        maxOutputTokens: Int64,
        reason!: AttemptPolicyReason = AttemptPolicyReason.Initial,
        softDeadlineMillis!: Int64 = 0,
        hardDeadlineMillis!: Int64 = 0,
        streamIdleMillis!: Int64 = 120000,
        resolvedPolicy!: ?ResolvedModelRequestPolicy = None
    ) {
        let noWholeAttemptDeadline = softDeadlineMillis == 0 && hardDeadlineMillis == 0
        let validWholeAttemptDeadline = softDeadlineMillis > 0 &&
            hardDeadlineMillis >= softDeadlineMillis
        if (model.trimAscii() == "" || maxOutputTokens < 1 ||
            (!noWholeAttemptDeadline && !validWholeAttemptDeadline) ||
            streamIdleMillis < 1) {
            throw IllegalArgumentException("model attempt policy is invalid")
        }
        this.model = model.trimAscii()
        this.thinking = thinking
        this.toolChoice = toolChoice
        this.maxOutputTokens = maxOutputTokens
        this.reason = reason
        this.softDeadlineMillis = softDeadlineMillis
        this.hardDeadlineMillis = hardDeadlineMillis
        this.streamIdleMillis = streamIdleMillis
        this.resolvedPolicy = resolvedPolicy
    }
}

// Store-owned evidence used by AgentThreadRuntime to attest a canonical Tool
// Call. It is not itself accepted by ToolPipeline or Operation Runtime.
public class CommittedToolCallSource {
    public let decisionId: ModelDecisionId
    public let scopedToolCallId: ScopedToolCallId
    public let canonicalItemId: ItemId
    public let block: ModelBlock

    public init(
        decisionId: ModelDecisionId,
        scopedToolCallId: ScopedToolCallId,
        canonicalItemId: ItemId,
        block: ModelBlock
    ) {
        if (block.kind != ModelBlockKind.ToolCall) {
            throw IllegalArgumentException("committed ToolCall source must contain a ToolCall")
        }
        this.decisionId = decisionId
        this.scopedToolCallId = scopedToolCallId
        this.canonicalItemId = canonicalItemId
        this.block = block
    }
}

// Facts observed from the provider protocol are stored separately from the
// validator's interpretation so historical decisions can be revalidated.
public class TerminalEvidence {
    public let protocol: String
    public let terminalEventKind: String
    public let rawStopReason: String
    public let messageTerminalObserved: Bool
    public let streamEofObserved: Bool
    public let adapterVersion: String

    public init(
        protocol: String,
        terminalEventKind: String,
        rawStopReason!: String = "",
        messageTerminalObserved!: Bool = false,
        streamEofObserved!: Bool = false,
        adapterVersion!: String = ""
    ) {
        if (protocol.trimAscii() == "" || adapterVersion.trimAscii() == "") {
            throw IllegalArgumentException(
                "terminal evidence requires protocol and adapter version"
            )
        }
        this.protocol = protocol.trimAscii()
        this.terminalEventKind = terminalEventKind.trimAscii()
        this.rawStopReason = rawStopReason
        this.messageTerminalObserved = messageTerminalObserved
        this.streamEofObserved = streamEofObserved
        this.adapterVersion = adapterVersion.trimAscii()
    }
}

// Low-frequency provider lifecycle facts. Text/reasoning/tool argument deltas
// remain ModelEvent variants and are not durable correctness state.
public enum ProviderStreamEvent {
    StreamStarted(String)
    | ControlledFaultInjected(String, Int64)
    | ContentBlockStarted(Int64, String)
    | ContentBlockCompleted(Int64, String)
    | MessageTerminalObserved(TerminalEvidence)
    | UsageDelta(Int64, Int64)
    | UsageCompleted(Int64, Int64)
    | ProviderError(String)
    | StreamTransportClosed
}

public class DurableModelAttempt {
    public let id: ModelAttemptId
    public let semanticRequestId: SemanticModelRequestId
    public let runId: RunId
    public let parentAttemptId: ?ModelAttemptId
    public let attemptNo: Int64
    public let lifecycle: ModelAttemptLifecycle
    public let policy: AgentValue
    public let policyReason: String
    public let startedAtMillis: Int64
    public let lastActivityAtMillis: Int64
    public let completedAtMillis: ?Int64
    public let providerRequestId: String
    public let providerResponseId: String
    public let failureKind: String
    public let semanticRequestDigest: String
    public let wirePolicyDigest: String
    public let dispatchState: ModelAttemptDispatchState
    public let replayBarrier: ModelAttemptReplayBarrier
    public let dispatchStartedAtMillis: ?Int64
    public let providerTerminalAtMillis: ?Int64

    public init(
        id: ModelAttemptId,
        semanticRequestId: SemanticModelRequestId,
        runId: RunId,
        attemptNo: Int64,
        lifecycle: ModelAttemptLifecycle,
        policy: AgentValue,
        policyReason: String,
        startedAtMillis: Int64,
        lastActivityAtMillis: Int64,
        parentAttemptId!: ?ModelAttemptId = None,
        completedAtMillis!: ?Int64 = None,
        providerRequestId!: String = "",
        providerResponseId!: String = "",
        failureKind!: String = "",
        semanticRequestDigest!: String = "",
        wirePolicyDigest!: String = "",
        dispatchState!: ModelAttemptDispatchState = ModelAttemptDispatchState.Prepared,
        replayBarrier!: ModelAttemptReplayBarrier = ModelAttemptReplayBarrier.NoBarrier,
        dispatchStartedAtMillis!: ?Int64 = None,
        providerTerminalAtMillis!: ?Int64 = None
    ) {
        if (attemptNo < 1 || startedAtMillis < 0 ||
            lastActivityAtMillis < startedAtMillis || match (completedAtMillis) {
                case Some(value) => value < lastActivityAtMillis
                case None => false
            }) {
            throw IllegalArgumentException("durable model attempt metadata is invalid")
        }
        this.id = id
        this.semanticRequestId = semanticRequestId
        this.runId = runId
        this.parentAttemptId = parentAttemptId
        this.attemptNo = attemptNo
        this.lifecycle = lifecycle
        this.policy = policy
        this.policyReason = policyReason
        this.startedAtMillis = startedAtMillis
        this.lastActivityAtMillis = lastActivityAtMillis
        this.completedAtMillis = completedAtMillis
        this.providerRequestId = providerRequestId
        this.providerResponseId = providerResponseId
        this.failureKind = failureKind
        this.semanticRequestDigest = semanticRequestDigest
        this.wirePolicyDigest = wirePolicyDigest
        this.dispatchState = dispatchState
        this.replayBarrier = replayBarrier
        this.dispatchStartedAtMillis = dispatchStartedAtMillis
        this.providerTerminalAtMillis = providerTerminalAtMillis
    }
}

public class DurableDecisionBlock {
    public let id: DecisionBlockId
    public let ordinal: Int64
    public let block: ModelBlock
    public let scopedToolCallId: ?ScopedToolCallId

    public init(
        id: DecisionBlockId,
        ordinal: Int64,
        block: ModelBlock,
        scopedToolCallId!: ?ScopedToolCallId = None
    ) {
        if (ordinal < 0) {
            throw IllegalArgumentException("decision block ordinal must not be negative")
        }
        if ((block.kind == ModelBlockKind.ToolCall) != scopedToolCallId.isSome()) {
            throw IllegalArgumentException(
                "only decision tool-call blocks require a scoped tool-call id"
            )
        }
        this.id = id
        this.ordinal = ordinal
        this.block = block
        this.scopedToolCallId = scopedToolCallId
    }
}

public class ModelDecision {
    public let id: ModelDecisionId
    public let attemptId: ModelAttemptId
    public let semanticRequestId: SemanticModelRequestId
    public let blocks: Array<DurableDecisionBlock>
    public let terminalEvidence: TerminalEvidence
    public let validationStatus: DecisionValidationStatus
    public let completionDisposition: CompletionDisposition
    public let outcome: DecisionOutcome
    public let contentHash: String
    public let replayHash: String
    public let validatorVersion: Int64
    public let providerId: String
    public let providerResponseId: String
    public let createdAtMillis: Int64

    public init(
        id: ModelDecisionId,
        attemptId: ModelAttemptId,
        semanticRequestId: SemanticModelRequestId,
        blocks: Array<DurableDecisionBlock>,
        terminalEvidence: TerminalEvidence,
        validationStatus: DecisionValidationStatus,
        completionDisposition: CompletionDisposition,
        outcome: DecisionOutcome,
        contentHash: String,
        replayHash: String,
        validatorVersion: Int64,
        providerId!: String = "",
        providerResponseId!: String = "",
        createdAtMillis!: Int64 = 0
    ) {
        if (blocks.isEmpty() || contentHash.trimAscii() == "" ||
            replayHash.trimAscii() == "" || validatorVersion < 1 ||
            createdAtMillis < 0) {
            throw IllegalArgumentException("durable model decision metadata is invalid")
        }
        for (index in 0..blocks.size where blocks[index].ordinal != index) {
            throw IllegalArgumentException("decision block ordinals must be contiguous")
        }
        this.id = id
        this.attemptId = attemptId
        this.semanticRequestId = semanticRequestId
        this.blocks = blocks
        this.terminalEvidence = terminalEvidence
        this.validationStatus = validationStatus
        this.completionDisposition = completionDisposition
        this.outcome = outcome
        this.contentHash = contentHash.trimAscii()
        this.replayHash = replayHash.trimAscii()
        this.validatorVersion = validatorVersion
        this.providerId = providerId
        this.providerResponseId = providerResponseId
        this.createdAtMillis = createdAtMillis
    }
}
