package agent_core

import agent_domain.*
import tool_runtime.*

// A same-process, deny-only restriction around the existing canonical start.
// It cannot supply a Run/Source/result, alter the request, or replace startTurn.
// Remote clients default to denial rather than serializing this live object.
public interface AgentRunStartRestriction111 {
    prop cancellation: CancellationToken
    func acquire(request: AgentRunRequest): Result<ToolExecutionHandoffLease>
    func check(request: AgentRunRequest): Result<Unit>
    // A notification only: original startTurn, snapshot and RunStarted have
    // already committed. It neither replaces admission nor constructs a Run.
    func admitted(request: AgentRunRequest): Result<Unit> { Result.Ok(()) }
}

func coreAcquireStartRestriction111(value: AgentRunStartRestriction111, request: AgentRunRequest): Result<ToolExecutionHandoffLease> {
    try {
        match (value.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        value.acquire(request)
    } catch (_: Exception) {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "child.start_restriction_failed", "live child-start restriction did not complete")) }
}
func coreNotifyStartRestriction111(value: AgentRunStartRestriction111, request: AgentRunRequest): Result<Unit> {
    try {
        match (value.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        value.admitted(request)
    } catch (_: Exception) {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "child.start_notification_failed", "actual child admission notification did not complete")) }
}
func coreCheckStartRestriction111(value: AgentRunStartRestriction111, request: AgentRunRequest): Result<Unit> {
    try {
        match (value.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        value.check(request)
    } catch (_: Exception) {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "child.start_restriction_failed", "live child-start restriction did not complete")) }
}
