package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

// A transient actual-user owner. No serialized approval or plugin response can
// reconstruct this object. Locks protect claims only; no executor runs locked.
public class HostDirectPreparationOwner {
    private let lock = Mutex()
    private var validation159e: ?() -> Result<Unit>
    private prop validate: () -> Result<Unit> { get() { validation159e.getOrThrow() } }
    let allowDeferred: Bool
    private var waiting: ?ApprovalRequest = None
    private var action: ?(ApprovalDecision, Bool) -> Result<ToolInvocationResult> = None
    private var choice: ?(ApprovalDecision) -> Result<Unit> = None
    private var completion: ?(Result<ToolInvocationResult>) -> Result<ToolInvocationResult> = None
    private var cleanup: ?() -> Unit = None
    private var acknowledgement: ?() -> Result<Unit> = None
    private var ownedFailures113: ?HostOwnedCheckpointFailureQueue113 = None<HostOwnedCheckpointFailureQueue113>
    private var ownedRun113: ?RunId = None<RunId>
    private var busy = true
    private var closed = false
    private var gatewayFrame159e: ?HostDirectGatewayFrame159e = None<HostDirectGatewayFrame159e>
    private var gatewayCalls159e: Int64 = 0
    private var gatewayAcknowledged159e = false
    private var stageSnapshotFrame159: ?ToolInvocationContext = None<ToolInvocationContext>
    // A thrown callback keeps its exact old Context privately retained. It
    // never receives a refund from the original RecoveryRequired fallback.
    private var unknownStageSnapshotFrame159: ?ToolInvocationContext = None<ToolInvocationContext>
    public init(validate: () -> Result<Unit>, allowDeferred!: Bool = true) { this.validation159e = Some(validate); this.allowDeferred = allowDeferred }
    public func current(): Result<Unit> {
        beginGatewayCall159e()
        try { currentGatewayCallFrame159e() } finally { endGatewayCall159e() }
    }

    private func beginGatewayCall159e(): Unit {
        lock.lock()
        try {
            if (gatewayCalls159e == Int64.Max) { throw IllegalStateException("gateway owner call count overflow") }
            gatewayCalls159e++
        } finally { lock.unlock() }
    }
    private func endGatewayCall159e(): Unit {
        let returned = detachReturnedGatewayFrame159e()
        match (returned) { case Some(frame) => frame.ownerReturned159e(); case None => () }
    }
    private func detachReturnedGatewayFrame159e(): ?HostDirectGatewayFrame159e {
        lock.lock()
        try {
            if (gatewayCalls159e <= 0) { throw IllegalStateException("gateway owner call was not entered") }
            gatewayCalls159e--
            if (gatewayFrame159e.isNone() || gatewayCalls159e != 0 || !gatewayAcknowledged159e || !closed || busy || waiting.isSome() ||
                action.isSome() || choice.isSome() || stageSnapshotFrame159.isSome() || unknownStageSnapshotFrame159.isSome()) {
                return None<HostDirectGatewayFrame159e> }
            // All actual callback/probe helpers returned, including concurrent
            // close probes. Clear the closures that captured the gateway Run.
            validation159e = None<() -> Result<Unit>>
            completion = None<(Result<ToolInvocationResult>) -> Result<ToolInvocationResult>>
            cleanup = None<() -> Unit>; acknowledgement = None<() -> Result<Unit>>
            let result = gatewayFrame159e; gatewayFrame159e = None<HostDirectGatewayFrame159e>
            result
        } finally { lock.unlock() }
    }
    private func currentGatewayCallFrame159e(): Result<Unit> {
        lock.lock()
        let actual = try { validation159e } finally { lock.unlock() }
        match (actual) { case Some(check) => check(); case None => directPreparationError("command.approval_owner_changed") }
    }
    func bind(finish: (Result<ToolInvocationResult>) -> Result<ToolInvocationResult>, close: () -> Unit,
        acknowledge: () -> Result<Unit>,
        ownedFailures113!: ?HostOwnedCheckpointFailureQueue113 = None<HostOwnedCheckpointFailureQueue113>,
        ownedRun113!: ?RunId = None<RunId>,
        gatewayFrame159e!: ?HostDirectGatewayFrame159e = None<HostDirectGatewayFrame159e>): Unit {
        lock.lock()
        try {
            if (completion.isSome() || closed) { throw IllegalStateException("Direct owner is already bound") }
            completion = Some(finish); cleanup = Some(close); acknowledgement = Some(acknowledge)
            this.ownedFailures113 = ownedFailures113; this.ownedRun113 = ownedRun113
            this.gatewayFrame159e = gatewayFrame159e
        } finally { lock.unlock() }
    }
    func retain(approval: ApprovalRequest, resume: (ApprovalDecision, Bool) -> Result<ToolInvocationResult>,
        validateChoice: (ApprovalDecision) -> Result<Unit>,
        ownedStageSnapshotFrame159!: ?ToolInvocationContext = None): Result<Unit> {
        lock.lock()
        try {
            if (closed || !busy || waiting.isSome()) { return directPreparationError("command.approval_owner_changed") }
            waiting = Some(approval); action = Some(resume); choice = Some(validateChoice)
            stageSnapshotFrame159 = ownedStageSnapshotFrame159
            Result.Ok(())
        } finally { lock.unlock() }
    }
    public func approval(): ?ApprovalRequest {
        lock.lock(); try { if (closed || busy) { None } else { waiting } } finally { lock.unlock() }
    }
    func complete(result: Result<ToolInvocationResult>): Result<ToolInvocationResult> {
        beginGatewayCall159e()
        try { completeGatewayCallFrame159e(result) } finally { endGatewayCall159e() }
    }
    private func completeGatewayCallFrame159e(result: Result<ToolInvocationResult>): Result<ToolInvocationResult> {
        let answer = completeFrame159(result)
        let returned = clearClosedStageSnapshotFrame159()
        try { match (returned) { case Some(value) => value.returnOwnedToolSetFrame159(); case None => () } }
        catch (error: Exception) {
            lock.lock(); try { unknownStageSnapshotFrame159 = returned } finally { lock.unlock() }; throw error
        }
        answer
    }
    func retainsStageSnapshotFrame159(frame: ToolInvocationContext): Bool {
        lock.lock()
        try { match (stageSnapshotFrame159) { case Some(value) => refEq(value, frame); case None => false } }
        finally { lock.unlock() }
    }
    private func clearClosedStageSnapshotFrame159(): ?ToolInvocationContext {
        lock.lock()
        try {
            if (!closed || busy || waiting.isSome() || action.isSome() || choice.isSome()) {
                return None<ToolInvocationContext> }
            let returned = stageSnapshotFrame159
            stageSnapshotFrame159 = None<ToolInvocationContext>
            returned
        } finally { lock.unlock() }
    }
    private func completeFrame159(result: Result<ToolInvocationResult>): Result<ToolInvocationResult> {
        lock.lock()
        let finish = try {
            if (waiting.isSome()) {
                match (result) { case Result.Ok(ToolInvocationResult.NeedsApproval(request)) =>
                    if (request.operationId.value == waiting.getOrThrow().operationId.value) { busy = false; return result }
                    case _ => () }
            }
            if (closed) { return directPreparationError("command.owner_closed") }
            closed = true; busy = false; waiting = None; action = None; choice = None
            completion
        } finally { lock.unlock() }
        try { match (finish) { case Some(value) => value(result); case None => result } }
        finally { match (cleanup) { case Some(value) => value(); case None => () } }
    }
    // Cleanup is not an execution outcome. Only the original gateway's
    // package-internal bind can provide this fixed actual-Run proof. A caller
    // cannot replace it with a serialized Receipt, callback or cancellation code.
    public func closeAcknowledgement(): Result<Unit> {
        beginGatewayCall159e()
        try {
            let result = closeAcknowledgementFrame159e()
            if (result.isOk()) {
                lock.lock(); try { gatewayAcknowledged159e = true } finally { lock.unlock() }
            }
            result
        } finally { endGatewayCall159e() }
    }
    private func closeAcknowledgementFrame159e(): Result<Unit> {
        lock.lock()
        let probe = try {
            if (completion.isNone() && cleanup.isNone() && acknowledgement.isNone()) {
                return Result.Ok(()) // This object has never acquired a Run.
            }
            if (!closed || busy || waiting.isSome() || acknowledgement.isNone()) {
                return directPreparationError("command.cleanup_not_acknowledged")
            }
            acknowledgement.getOrThrow()
        } finally { lock.unlock() }
        probe()
    }
    public func decide(operationId: String, decision: ApprovalDecision): Result<ToolInvocationResult> {
        return resume(operationId, decision, false)
    }
    public func decideOwnedCheckpointFailure113(operationId: String,
        decision: ApprovalDecision): OwnedHostDirectToolResult113 {
        ownedResult113(decide(operationId, decision))
    }
    public func cancelOwnedCheckpointFailure113(): OwnedHostDirectToolResult113 {
        ownedResult113(cancel())
    }
    public func takeOwnedCheckpointFailure113(): OwnedHostDirectToolResult113 {
        ownedResult113(Result<ToolInvocationResult>.Err(hostOwnedCheckpointFailurePending113()))
    }
    private func ownedResult113(original: Result<ToolInvocationResult>): OwnedHostDirectToolResult113 {
        lock.lock()
        let (queue, run) = try { (ownedFailures113, ownedRun113) } finally { lock.unlock() }
        if (queue.isNone() || run.isNone()) { return OwnedHostDirectToolResult113.Existing(original) }
        queue.getOrThrow().take(run.getOrThrow(), original)
    }
    public func cancel(): Result<ToolInvocationResult> {
        let pending = approval()
        match (pending) { case Some(value) => resume(value.operationId.value, ApprovalDecision.Reject, true)
            case None => directPreparationError("command.approval_not_pending") }
    }
    private func resume(operationId: String, decision: ApprovalDecision, cancelling: Bool): Result<ToolInvocationResult> {
        beginGatewayCall159e()
        try { resumeGatewayCallFrame159e(operationId, decision, cancelling) } finally { endGatewayCall159e() }
    }
    private func resumeGatewayCallFrame159e(operationId: String, decision: ApprovalDecision, cancelling: Bool): Result<ToolInvocationResult> {
        var returnedStage159: ?ToolInvocationContext = None<ToolInvocationContext>
        var closingStage159: ?ToolInvocationContext = None<ToolInvocationContext>
        lock.lock()
        var next: ?(ApprovalDecision, Bool) -> Result<ToolInvocationResult> = try {
            if (closed || busy || waiting.isNone() || action.isNone() || choice.isNone() || waiting.getOrThrow().operationId.value != operationId) {
                return directPreparationError("command.approval_mismatch") }
            // This callback validates only immutable review/choice data; it
            // must not enter Runtime/Store or call an executor while locked.
            if (!cancelling) { match (choice.getOrThrow()(decision)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
            busy = true; waiting = None; choice = None
            returnedStage159 = stageSnapshotFrame159
            stageSnapshotFrame159 = None<ToolInvocationContext>
            let value = action.getOrThrow(); action = None; Some(value)
        } finally { lock.unlock() }
        let result = try {
            let value = hostInvokeDirectApprovalFrame159(next.getOrThrow(), decision, cancelling)
            // The entire callback/helper has returned. Both owner callback
            // fields and this local closure alias clear before its share.
            next = None<(ApprovalDecision, Bool) -> Result<ToolInvocationResult>>
            closingStage159 = returnedStage159
            returnedStage159 = None<ToolInvocationContext>
            match (closingStage159) { case Some(frame) => frame.returnOwnedToolSetFrame159(); case None => () }
            closingStage159 = None<ToolInvocationContext>
            value
        } catch (_: Exception) {
            lock.lock()
            try { unknownStageSnapshotFrame159 = if (returnedStage159.isSome()) { returnedStage159 } else { closingStage159 } }
            finally { lock.unlock() }
            Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "command.approval_execution_failed", "Direct approval retained unsettled canonical work")) }
        complete(result)
    }
}
func directPreparationError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, "Direct preparation requires its retained actual user owner"))
}
