package agent_runtime

import agent_domain.*
import std.sync.*
import yjson_support.*

type ManagedJobOwnerCheck = () -> Result<Unit>

func managedJobDenied<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code,
        "managed job requires its exact live reservation and completed canonical launch"))
}

// Only the current AgentThreadRuntime can construct this reservation. A Store
// binding or restored task journal is descriptive evidence, never this seal.
public class ManagedJobReservation {
    public let binding: ManagedJobLaunchBinding
    private let operations: OperationRuntimePort
    private let cancellation: CancellationSource
    private let clock: () -> Int64
    private let lock = Mutex()
    private var consumed = false
    private var admissionIssued = false
    init(binding: ManagedJobLaunchBinding, operations: OperationRuntimePort,
        parent: CancellationToken, clock: () -> Int64) {
        this.binding = binding; this.operations = operations; this.clock = clock
        cancellation = CancellationSource(parent: Some(parent), deadlineMillis: binding.declaration.deadlineMillis)
    }
    public prop cancellationToken: CancellationToken { get() { cancellation.token } }
    public func launchResult(): ToolResult { ToolResult(binding.parentCallId, managedJobLaunchOutput(binding)) }
    public func cancel(): Unit { let _ = cancellation.cancel() }
    // A failed launch may have no child owner at all. Release its parent
    // subscription without allowing this path to detach a live admission.
    public func detachUnclaimedParent(): Unit {
        lock.lock()
        try {
            if (admissionIssued) { return }
            consumed = true
            cancellation.close()
        } finally { lock.unlock() }
    }

    // The Task owner retains this handle while waiting for the parent Receipt.
    // A missing Receipt is not consumed: it may await the original commit only.
    // Once claimed, a second process/runtime can never claim the same job.
    public func claim(): Result<ManagedJobAdmission> {
        lock.lock()
        try {
            if (consumed) { return managedJobDenied("task.managed_job_consumed") }
            match (cancellation.token.check(nowMillis: clock())) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (operations.claimManagedJobLaunch(binding)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
            consumed = true
            match (cancellation.token.check(nowMillis: clock())) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let admission = ManagedJobAdmission(binding, operations, cancellation, clock)
            admissionIssued = true
            Result.Ok(admission)
        } finally { lock.unlock() }
    }
}

// This admission permits starting precisely the frozen child Task Run. It is
// not a PreparedToolInvocation, OperationRootSource, lease, or approval token.
// Child execution still needs its own current canonical Task source/Operation.
public class ManagedJobAdmission {
    public let binding: ManagedJobLaunchBinding
    private let operations: OperationRuntimePort
    private let cancellation: CancellationSource
    private let clock: () -> Int64
    private let ownerLock = Mutex()
    private var ownerReserved = false
    private var ownerCurrent: ?ManagedJobOwnerCheck = None
    private var invocationToken: ?CancellationToken = None
    init(binding: ManagedJobLaunchBinding, operations: OperationRuntimePort,
        cancellation: CancellationSource, clock: () -> Int64) {
        this.binding = binding; this.operations = operations; this.cancellation = cancellation; this.clock = clock
    }
    public prop cancellationToken: CancellationToken { get() { cancellation.token } }
    public func validateLaunch(): Result<Unit> {
        match (cancellation.token.check(nowMillis: clock())) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        operations.verifyManagedJobLaunch(binding)
    }
    public func cancel(): Unit { let _ = cancellation.cancel() }
    public func frozenPlan(): Result<NormalizedOperationPlan> {
        match (validateLaunch()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let plan = match (operations.loadPlan(binding.parentOperationId, binding.parentRunId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (operations.verifyManagedJobPlan(binding, plan)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(plan) }
    }
    func reserveOwner(threadId: ThreadId): Result<Unit> {
        match (validateLaunch()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        ownerLock.lock()
        try {
            if (ownerReserved || threadId.value != binding.declaration.threadId.value) { return managedJobDenied("task.managed_job_owner_consumed") }
            ownerReserved = true
            Result.Ok(())
        } finally { ownerLock.unlock() }
    }
    func bindOwner(check: () -> Result<Unit>, token: CancellationToken): Unit {
        ownerLock.lock()
        try {
            if (!ownerReserved || ownerCurrent.isSome()) { throw IllegalStateException("managed task owner binding is not fresh") }
            ownerCurrent = Some(check); invocationToken = Some(token)
        } finally { ownerLock.unlock() }
    }
    func token(): CancellationToken {
        ownerLock.lock()
        try { invocationToken.getOrThrow() } finally { ownerLock.unlock() }
    }
    private func currentOwnerCheck(): ?ManagedJobOwnerCheck {
        ownerLock.lock()
        try { ownerCurrent } finally { ownerLock.unlock() }
    }
    func validateInvocation(call: ToolCall): Result<Unit> {
        match (validateLaunch()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let current = match (currentOwnerCheck()) { case Some(value) => value
            case None => return managedJobDenied("task.managed_job_owner_missing") }
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let original = match (operations.loadCall(binding.parentOperationId, binding.parentRunId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (call.callId != original.callId || call.name != original.name ||
            canonicalAgentValue(call.arguments) != canonicalAgentValue(original.arguments)) {
            return managedJobDenied("task.managed_job_call_changed")
        }
        Result.Ok(())
    }
    func validatePlan(plan: NormalizedOperationPlan): Result<Unit> {
        match (validateLaunch()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let current = match (currentOwnerCheck()) { case Some(value) => value
            case None => return managedJobDenied("task.managed_job_owner_missing") }
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        operations.verifyManagedJobPlan(binding, plan)
    }
    // Only after the actual child owner has acknowledged cleanup. Closing this
    // subscription is deliberately not a substitute for cancellation or ACK.
    public func detachParentAfterCleanup(): Unit { cancellation.close() }
}

func managedJobOriginForRun(snapshot: AgentThreadSnapshot, turnId: SemanticTurnId, runId: RunId): ?ManagedJobLaunchBinding {
    for (turn in snapshot.turns where turn.id.value == turnId.value) {
        for (item in snapshot.items where item.id.value == turn.userItemId.value) {
            if (isManagedJobInitiator(item)) {
                match (item.provenance.directOrigin) {
                    case Some(DirectCallOrigin.ManagedJob(value)) =>
                        if (value.declaration.runId.value != runId.value) { throw IllegalArgumentException("managed Task origin belongs to another Run") }
                        return Some(value)
                    case _ => ()
                }
            }
        }
    }
    None
}
