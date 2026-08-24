package agent_runtime

import std.collection.*
import std.sync.*
import agent_domain.*

// Capability handed to ToolPipeline and Operation Runtime only after the
// canonical Thread has attested the durable Decision source binding. The
// constructor is package-private, so provisional provider content cannot mint
// one outside agent_runtime.
public class CommittedToolCallRef {
    public let decisionId: ModelDecisionId
    public let scopedToolCallId: ScopedToolCallId
    public let canonicalItemId: ItemId
    public let block: ModelBlock

    init(source: CommittedToolCallSource) {
        this.decisionId = source.decisionId
        this.scopedToolCallId = source.scopedToolCallId
        this.canonicalItemId = source.canonicalItemId
        this.block = source.block
    }
}

public interface ModelDecisionRuntimePort {
    func abandonOpenAttempts(runId: RunId, abandonedAtMillis: Int64): Result<Unit>
    func createAttempt(attempt: DurableModelAttempt): Result<Unit>
    func terminalizeAttempt(
        attemptId: ModelAttemptId,
        lifecycle: ModelAttemptLifecycle,
        failureKind: String,
        completedAtMillis: Int64
    ): Result<Unit>
    func persistValidatedDecision(decision: ModelDecision): Result<Unit>
    func finalizeUsage(
        decisionId: ModelDecisionId,
        usage: ModelUsage,
        finalizedAtMillis: Int64
    ): Result<Unit>
    func uncommittedDecision(runId: RunId): Result<?ModelDecision>
    func recordCanonicalProjection(
        decisionId: ModelDecisionId,
        sources: Array<CommittedToolCallSource>
    ): Result<Unit>
    func committedToolCallSources(runId: RunId): Result<Array<CommittedToolCallSource>>
}

class MemoryDecisionEntry {
    let decision: ModelDecision
    var canonicalCommitted: Bool = false
    var sources: Array<CommittedToolCallSource> = []
    init(decision: ModelDecision) { this.decision = decision }
}

// Explicitly ephemeral default for tests/embedders. Product composition uses
// the SQLite implementation; this implementation preserves the same API and
// never turns stream observations into decisions.
public class InMemoryModelDecisionRuntimePort <: ModelDecisionRuntimePort {
    private let lock = Mutex()
    private let attempts = ArrayList<DurableModelAttempt>()
    private let decisions = ArrayList<MemoryDecisionEntry>()

    public init() {}

    public func abandonOpenAttempts(runId: RunId, abandonedAtMillis: Int64): Result<Unit> {
        let _ = runId.value
        let _ = abandonedAtMillis
        Result.Ok(())
    }

    public func createAttempt(attempt: DurableModelAttempt): Result<Unit> {
        lock.lock()
        try {
            for (existing in attempts where existing.id.value == attempt.id.value) {
                return if (existing.semanticRequestId.value == attempt.semanticRequestId.value &&
                    existing.attemptNo == attempt.attemptNo) { Result.Ok(()) } else {
                    decisionPortConflict("model.attempt_identity_drift")
                }
            }
            attempts.add(attempt)
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func terminalizeAttempt(
        attemptId: ModelAttemptId,
        lifecycle: ModelAttemptLifecycle,
        failureKind: String,
        completedAtMillis: Int64
    ): Result<Unit> {
        let _ = lifecycle
        let _ = failureKind
        let _ = completedAtMillis
        lock.lock()
        try {
            for (attempt in attempts where attempt.id.value == attemptId.value) {
                return Result.Ok(())
            }
            decisionPortConflict("model.attempt_not_found")
        } finally { lock.unlock() }
    }

    public func persistValidatedDecision(decision: ModelDecision): Result<Unit> {
        if (decision.validationStatus != DecisionValidationStatus.Validated ||
            !decision.terminalEvidence.messageTerminalObserved) {
            return decisionPortConflict("model.decision_not_validated")
        }
        lock.lock()
        try {
            for (entry in decisions where entry.decision.id.value == decision.id.value) {
                return if (entry.decision.contentHash == decision.contentHash &&
                    entry.decision.replayHash == decision.replayHash) { Result.Ok(()) } else {
                    decisionPortConflict("model.decision_identity_drift")
                }
            }
            decisions.add(MemoryDecisionEntry(decision))
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func finalizeUsage(
        decisionId: ModelDecisionId,
        usage: ModelUsage,
        finalizedAtMillis: Int64
    ): Result<Unit> {
        let _ = usage.inputTokens
        let _ = finalizedAtMillis
        lock.lock()
        try {
            for (entry in decisions where entry.decision.id.value == decisionId.value) {
                return Result.Ok(())
            }
            decisionPortConflict("model.decision_not_found")
        } finally { lock.unlock() }
    }

    public func uncommittedDecision(runId: RunId): Result<?ModelDecision> {
        lock.lock()
        try {
            var found: ?ModelDecision = None
            for (entry in decisions where !entry.canonicalCommitted) {
                for (attempt in attempts where attempt.id.value == entry.decision.attemptId.value &&
                    attempt.runId.value == runId.value) {
                    if (found.isSome()) {
                        return decisionPortConflict("model.multiple_uncommitted_decisions")
                    }
                    found = Some(entry.decision)
                }
            }
            Result.Ok(found)
        } finally { lock.unlock() }
    }

    public func decisionForSemanticRequest(
        semanticRequestId: SemanticModelRequestId
    ): Result<?ModelDecision> {
        lock.lock()
        try {
            var found: ?ModelDecision = None
            for (entry in decisions where
                entry.decision.semanticRequestId.value == semanticRequestId.value) {
                if (found.isSome()) {
                    return decisionPortConflict("model.multiple_request_decisions")
                }
                found = Some(entry.decision)
            }
            Result.Ok(found)
        } finally { lock.unlock() }
    }

    public func recordCanonicalProjection(
        decisionId: ModelDecisionId,
        sources: Array<CommittedToolCallSource>
    ): Result<Unit> {
        lock.lock()
        try {
            for (entry in decisions where entry.decision.id.value == decisionId.value) {
                if (entry.canonicalCommitted) {
                    return if (sameCommittedSources(entry.sources, sources)) {
                        Result.Ok(())
                    } else { decisionPortConflict("model.canonical_projection_drift") }
                }
                entry.sources = sources
                entry.canonicalCommitted = true
                return Result.Ok(())
            }
            decisionPortConflict("model.decision_not_found")
        } finally { lock.unlock() }
    }

    public func committedToolCallSources(runId: RunId): Result<Array<CommittedToolCallSource>> {
        lock.lock()
        try {
            let output = ArrayList<CommittedToolCallSource>()
            for (entry in decisions where entry.canonicalCommitted) {
                for (attempt in attempts where attempt.id.value == entry.decision.attemptId.value &&
                    attempt.runId.value == runId.value) {
                    output.add(all: entry.sources)
                }
            }
            Result.Ok(output.toArray())
        } finally { lock.unlock() }
    }
}

func sameCommittedSources(
    left: Array<CommittedToolCallSource>,
    right: Array<CommittedToolCallSource>
): Bool {
    if (left.size != right.size) { return false }
    for (index in 0..left.size) {
        if (left[index].decisionId.value != right[index].decisionId.value ||
            left[index].scopedToolCallId.value != right[index].scopedToolCallId.value ||
            left[index].canonicalItemId.value != right[index].canonicalItemId.value ||
            left[index].block.callId != right[index].block.callId ||
            left[index].block.name != right[index].block.name ||
            !sameDecisionValue(left[index].block.arguments,
                right[index].block.arguments)) {
            return false
        }
    }
    true
}

func sameDecisionValue(left: AgentValue, right: AgentValue): Bool {
    match (left.kind) {
        case ValueKind.Null => match (right.kind) {
            case ValueKind.Null => true
            case _ => false
        }
        case ValueKind.Boolean => match (right.kind) {
            case ValueKind.Boolean => left.boolean == right.boolean
            case _ => false
        }
        case ValueKind.Number => match (right.kind) {
            case ValueKind.Number => left.number == right.number
            case _ => false
        }
        case ValueKind.Text => match (right.kind) {
            case ValueKind.Text => left.text == right.text
            case _ => false
        }
        case ValueKind.List => match (right.kind) {
            case ValueKind.List =>
                if (left.items.size != right.items.size) { return false }
                for (index in 0..left.items.size where
                    !sameDecisionValue(left.items[index], right.items[index])) {
                    return false
                }
                true
            case _ => false
        }
        case ValueKind.Object => match (right.kind) {
            case ValueKind.Object =>
                if (left.fields.size != right.fields.size) { return false }
                for (index in 0..left.fields.size) {
                    if (left.fields[index].name != right.fields[index].name ||
                        !sameDecisionValue(left.fields[index].value,
                            right.fields[index].value)) {
                        return false
                    }
                }
                true
            case _ => false
        }
    }
}

func decisionPortConflict<T>(code: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Conflict, code, "Model Attempt/Decision state conflicts with durable identity"
    ))
}
