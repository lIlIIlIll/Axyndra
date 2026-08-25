package agent_domain

import std.deriving.*

public class StepId {
    public let value: String
    public init(value: String) {
        if (value.trimAscii() == "") { throw IllegalArgumentException("Step id is empty") }
        this.value = value.trimAscii()
    }
}

@Derive[Equatable]
public enum InboxEntryKind {
    UserPrompt | Steering | ContextInjection | ApprovalDecision
    | ExternalCompletion | ChildRunMessage | Cancel | Close
}

@Derive[Equatable]
public enum InboxEntryStatus {
    Queued | Claimed | Applied | Rejected | Superseded
}

@Derive[Equatable]
public enum InboxEnqueueOutcome {
    Inserted | AlreadyQueued | AlreadyClaimed | AlreadyApplied
    | AlreadyRejected | AlreadySuperseded
}

@Derive[Equatable]
public enum StepStatus {
    Open | Completed | Cancelled | Failed | Quarantined | Interrupted
}

public class DurableInboxEntry {
    public let id: InboxEntryId
    public let threadId: ThreadId
    public let laneId: LaneId
    public let kind: InboxEntryKind
    public let payload: AgentValue
    public let status: InboxEntryStatus
    public let createdAtMillis: Int64
    public let claimedStepId: ?StepId

    public init(
        id: InboxEntryId,
        threadId: ThreadId,
        laneId: LaneId,
        kind: InboxEntryKind,
        payload: AgentValue,
        status!: InboxEntryStatus = InboxEntryStatus.Queued,
        createdAtMillis!: Int64 = 0,
        claimedStepId!: ?StepId = None
    ) {
        if (payload.kind != ValueKind.Object || createdAtMillis < 0 ||
            (status == InboxEntryStatus.Claimed && claimedStepId.isNone()) ||
            (status == InboxEntryStatus.Queued && claimedStepId.isSome())) {
            throw IllegalArgumentException("durable Inbox entry is invalid")
        }
        this.id = id
        this.threadId = threadId
        this.laneId = laneId
        this.kind = kind
        this.payload = payload
        this.status = status
        this.createdAtMillis = createdAtMillis
        this.claimedStepId = claimedStepId
    }
}

// Correlation ids are caller-local. Durable Inbox identity includes its full
// Thread/Lane enclosure so the same external correlation can safely recur in
// another Thread without competing for a global SQLite key.
public func scopedInboxEntryId(
    threadId: ThreadId,
    laneId: LaneId,
    correlationId: String
): InboxEntryId {
    let normalized = correlationId.trimAscii()
    if (normalized == "") {
        throw IllegalArgumentException("Inbox correlation id is empty")
    }
    InboxEntryId("inbox-" + modelPolicySha256Text(
        threadId.value + "\n" + laneId.value + "\n" + normalized
    ))
}

public class StepRecord {
    public let id: StepId
    public let threadId: ThreadId
    public let laneId: LaneId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let ordinal: Int64
    public let inputEntryId: ?InboxEntryId
    public let acceptedItemId: ?ItemId
    public let status: StepStatus
    public let openedAtMillis: Int64
    public let settledAtMillis: ?Int64

    public init(
        id: StepId,
        threadId: ThreadId,
        laneId: LaneId,
        turnId: SemanticTurnId,
        runId: RunId,
        ordinal: Int64,
        inputEntryId!: ?InboxEntryId = None,
        acceptedItemId!: ?ItemId = None,
        status!: StepStatus = StepStatus.Open,
        openedAtMillis!: Int64 = 0,
        settledAtMillis!: ?Int64 = None
    ) {
        if (ordinal < 0 || openedAtMillis < 0 ||
            inputEntryId.isSome() != acceptedItemId.isSome() ||
            (status == StepStatus.Open && settledAtMillis.isSome()) ||
            (status != StepStatus.Open && settledAtMillis.isNone())) {
            throw IllegalArgumentException("Step record enclosure is invalid")
        }
        this.id = id
        this.threadId = threadId
        this.laneId = laneId
        this.turnId = turnId
        this.runId = runId
        this.ordinal = ordinal
        this.inputEntryId = inputEntryId
        this.acceptedItemId = acceptedItemId
        this.status = status
        this.openedAtMillis = openedAtMillis
        this.settledAtMillis = settledAtMillis
    }
}

public func inboxEntryKindName(value: InboxEntryKind): String {
    match (value) {
        case InboxEntryKind.UserPrompt => "user_prompt"
        case InboxEntryKind.Steering => "steering"
        case InboxEntryKind.ContextInjection => "context_injection"
        case InboxEntryKind.ApprovalDecision => "approval_decision"
        case InboxEntryKind.ExternalCompletion => "external_completion"
        case InboxEntryKind.ChildRunMessage => "child_run_message"
        case InboxEntryKind.Cancel => "cancel"
        case InboxEntryKind.Close => "close"
    }
}

public func inboxEntryStatusName(value: InboxEntryStatus): String {
    match (value) {
        case InboxEntryStatus.Queued => "queued"
        case InboxEntryStatus.Claimed => "claimed"
        case InboxEntryStatus.Applied => "applied"
        case InboxEntryStatus.Rejected => "rejected"
        case InboxEntryStatus.Superseded => "superseded"
    }
}

public func stepStatusName(value: StepStatus): String {
    match (value) {
        case StepStatus.Open => "open"
        case StepStatus.Completed => "completed"
        case StepStatus.Cancelled => "cancelled"
        case StepStatus.Failed => "failed"
        case StepStatus.Quarantined => "quarantined"
        case StepStatus.Interrupted => "interrupted"
    }
}
