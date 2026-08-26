package agent_ports

import yjson_support.*

import yjson.*

import agent_domain.*

public class TransactionPreconditions {
    public let threadId: ThreadId
    public let expectedThreadRevision: Int64
    public let runId: RunId
    public let expectedContinuationRevision: Int64

    public init(
        threadId: ThreadId,
        expectedThreadRevision: Int64,
        runId: RunId,
        expectedContinuationRevision: Int64
    ) {
        if (expectedThreadRevision < 0 || expectedContinuationRevision < 0) {
            throw IllegalArgumentException("semantic transaction revision must not be negative")
        }
        this.threadId = threadId
        this.expectedThreadRevision = expectedThreadRevision
        this.runId = runId
        this.expectedContinuationRevision = expectedContinuationRevision
    }
}

public class SemanticAuditEntry {
    public let kind: String
    public let payload: AgentValue
    public let observedAtMillis: Int64

    public init(kind: String, payload: AgentValue, observedAtMillis: Int64) {
        if (kind.trimAscii() == "" || payload.unifiedKind != ValueKind.Object || observedAtMillis < 0) {
            throw IllegalArgumentException("semantic audit entry is invalid")
        }
        this.kind = kind.trimAscii()
        this.payload = payload
        this.observedAtMillis = observedAtMillis
    }
}

public class SemanticAppEvent {
    public let eventId: String
    public let kind: String
    public let payload: AgentValue
    public let createdAtMillis: Int64

    public init(eventId: String, kind: String, payload: AgentValue, createdAtMillis: Int64) {
        if (eventId.trimAscii() == "" || kind.trimAscii() == "" ||
            payload.unifiedKind != ValueKind.Object || createdAtMillis < 0) {
            throw IllegalArgumentException("semantic App event is invalid")
        }
        this.eventId = eventId.trimAscii()
        this.kind = kind.trimAscii()
        this.payload = payload
        this.createdAtMillis = createdAtMillis
    }
}

public class DurableWriteSet {
    public let continuation: ?DurableRunContinuationV1
    public let removeContinuation: Bool
    public let auditEntries: Array<SemanticAuditEntry>
    public let appEvents: Array<SemanticAppEvent>

    public init(
        continuation!: ?DurableRunContinuationV1 = None,
        removeContinuation!: Bool = false,
        auditEntries!: Array<SemanticAuditEntry> = [],
        appEvents!: Array<SemanticAppEvent> = []
    ) {
        if (continuation.isSome() && removeContinuation) {
            throw IllegalArgumentException("continuation register cannot be put and removed together")
        }
        this.continuation = continuation
        this.removeContinuation = removeContinuation
        this.auditEntries = auditEntries
        this.appEvents = appEvents
    }

    public func isEmpty(): Bool {
        continuation.isNone() && !removeContinuation &&
            auditEntries.isEmpty() && appEvents.isEmpty()
    }
}

public class CommitReceipt {
    public let threadId: ThreadId
    public let commitSequence: Int64
    public let continuationRevision: Int64
    public let outboxEventIds: Array<String>

    public init(
        threadId: ThreadId,
        commitSequence: Int64,
        continuationRevision: Int64,
        outboxEventIds: Array<String>
    ) {
        if (commitSequence < 1 || continuationRevision < 0) {
            throw IllegalArgumentException("semantic commit receipt is invalid")
        }
        this.threadId = threadId
        this.commitSequence = commitSequence
        this.continuationRevision = continuationRevision
        this.outboxEventIds = outboxEventIds
    }
}

public class AppOutboxRecord {
    public let event: SemanticAppEvent
    public let threadId: ThreadId
    public let commitSequence: Int64
    public let ordinal: Int64

    public init(
        event: SemanticAppEvent,
        threadId: ThreadId,
        commitSequence: Int64,
        ordinal: Int64
    ) {
        if (commitSequence < 1 || ordinal < 0) {
            throw IllegalArgumentException("App outbox record is invalid")
        }
        this.event = event
        this.threadId = threadId
        this.commitSequence = commitSequence
        this.ordinal = ordinal
    }
}

public interface SemanticStore {
    func transact(
        expected: TransactionPreconditions,
        writes: DurableWriteSet
    ): Result<CommitReceipt>

    func continuation(runId: RunId): Result<DurableRunContinuationV1>

    func pendingOutbox(threadId: ThreadId, afterCommitSequence: Int64): Result<Array<AppOutboxRecord>>

    func acknowledgeOutbox(threadId: ThreadId, throughCommitSequence: Int64): Result<Unit>
}
