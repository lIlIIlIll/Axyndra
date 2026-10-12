package agent_runtime

import agent_domain.*

// Identity validation is shared by the actual durable port and the in-memory
// contract port. The source, authority, plan and handoff are checked separately.
public func validateDerivedInvocationCall(call: ToolCall, plan: NormalizedOperationPlan): Result<Unit> {
    if (call.callId.trimAscii() == "" || call.callId.size > 1024 || call.callId.contains("\u{0000}") ||
        call.name != plan.toolName || canonicalAgentValue(call.arguments) != canonicalAgentValue(plan.canonicalArguments)) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "operation.derived_call_invalid",
            "derived invocation must preserve the exact host-prepared call and canonical arguments"))
    }
    Result.Ok(())
}
