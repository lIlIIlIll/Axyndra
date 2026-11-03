package agent_runtime

import agent_domain.*
import std.sync.*

func continuationDenied<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code,
        "continuation requires the exact current host user control and unused Run admission"))
}

// Trusted composition implements this using its nonserializable user-command
// scope. No plugin, source DTO, audit reader or restored journal is an authorizer.
public interface ContinuationRunAuthorizer {
    func authorizeNextRun(): Result<ContinuationRunOrigin>
    func validateCurrent(origin: ContinuationRunOrigin): Result<Unit>
    // Called synchronously while the authority and supplied Store transaction
    // are already held. Only immutable deadlines/atomic cancellation state are
    // allowed here: never acquire Host/Runtime/Store/owner locks or do I/O.
    // Existing non-document authorizers have no separate query time window.
    func validateStartWindow(origin: ContinuationRunOrigin): Result<Unit> { Result.Ok(()) }
}

// This is a live control owner, not a token budget ledger. Pause/restart revoke
// it before editing durable control facts. It is never a parent cancellation
// source of an already admitted Run: pause retains the original between-Run gate.
public class ContinuationRunAuthority {
    private let authorizer: ContinuationRunAuthorizer
    private let lock = Mutex()
    private var revoked = false
    public init(authorizer: ContinuationRunAuthorizer) { this.authorizer = authorizer }
    public func revoke(): Unit { lock.lock(); try { revoked = true } finally { lock.unlock() } }
    func validateStartWindow(origin: ContinuationRunOrigin): Result<Unit> {
        authorizer.validateStartWindow(origin)
    }
    public func reserve(): Result<ContinuationRunAdmission> {
        lock.lock()
        try {
            if (revoked) { return continuationDenied("continuation.control_revoked") }
            let origin = match (authorizer.authorizeNextRun()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            match (authorizer.validateCurrent(origin)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(ContinuationRunAdmission(origin, this))
        } finally { lock.unlock() }
    }
    func start(admission: ContinuationRunAdmission, action: () -> Result<ActiveRunSnapshot>): Result<ActiveRunSnapshot> {
        lock.lock()
        try {
            if (revoked) { return continuationDenied("continuation.control_revoked") }
            match (authorizer.validateCurrent(admission.origin)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!admission.consume()) { return continuationDenied("continuation.admission_consumed") }
            // Owner lock linearizes pause against the full SQLite admission.
            // The transaction verifier never calls Runtime/this authorizer.
            admission.enter()
            try { action() } finally { admission.leave() }
        } finally { lock.unlock() }
    }
}

public class ContinuationRunAdmission {
    public let origin: ContinuationRunOrigin
    private let owner: ContinuationRunAuthority
    // Accessed only while the owning authority holds its mutex.
    private var consumed = false
    private let starting = AtomicBool(false)
    init(origin: ContinuationRunOrigin, owner: ContinuationRunAuthority) { this.origin = origin; this.owner = owner }
    func consume(): Bool { if (consumed) { return false }; consumed = true; true }
    func enter(): Unit { starting.store(true) }
    func leave(): Unit { starting.store(false) }
    func start(action: () -> Result<ActiveRunSnapshot>): Result<ActiveRunSnapshot> { owner.start(this, action) }
    // A local liveness check, not a replacement for exact transition binding.
    public func verifyStartWindow(): Result<Unit> {
        if (!starting.load()) { return continuationDenied("continuation.admission_not_starting") }
        owner.validateStartWindow(origin)
    }
    // Store can test a real transient seal but cannot construct one from origin.
    // Only the Runtime start path opens this finite window under its live owner.
    public func verifyTransition(transition: ThreadTransition): Result<Unit> {
        if (!starting.load() || transition.kind != ThreadTransitionKind.TurnStarted || transition.committedItems.size != 1 ||
            transition.committedTurn.isNone()) { return continuationDenied("continuation.admission_not_starting") }
        let item = transition.committedItems[0]
        if (!isContinuationInitiatorDescription(item) || !sameContinuationRunOrigin(item.provenance.continuationOrigin.getOrThrow(), origin) ||
            item.threadId.value != origin.threadId || item.turnId.value != origin.turnId || item.id.value != origin.initiatorItemId ||
            transition.before.thread.revision != origin.expectedThreadRevision || transition.after.activeEpoch != origin.epoch ||
            transition.after.activeRunId.isNone() || transition.after.activeRunId.getOrThrow().value != origin.runId || transition.executionLaneId.value != origin.laneId ||
            modelPolicySha256Text(canonicalAgentValue(transition.continuationRequest)) != origin.requestDigest ||
            continuationRunLaunchDigest(transition.runLaneSnapshot, transition.runContextSnapshot, transition.runBudgetSnapshot) != origin.launchDigest) {
            return continuationDenied("continuation.admission_binding_changed")
        }
        verifyStartWindow()
    }
}
