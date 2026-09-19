package agent_testkit

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Test-only compatibility for isolated ToolPipeline contract fixtures. This
// keeps raw ToolCall construction out of production execution while still
// exercising the real prepare -> canonical Operation -> prepared execution
// lifecycle in package-level tests.
public func executePipelineCall(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    call: ToolCall,
    persistResult!: Bool = true
): Result<ToolInvocationResult> {
    match (pipeline.prepare(context, call)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(ToolPreparation.Ready(prepared)) =>
            match (prepareDirectOperation(pipeline, context, prepared)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => executePreparedAndPersist(
                    pipeline, context, prepared, persistResult
                )
            }
        case Result.Ok(ToolPreparation.NeedsApproval(prepared, request)) =>
            match (prepareDirectOperation(pipeline, context, prepared)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) =>
                    match (pipeline.operationRuntime().waitForApproval(
                        prepared.operationId, context.runId
                    )) {
                        case Result.Ok(_) => Result.Ok(
                            ToolInvocationResult.NeedsApproval(request)
                        )
                        case Result.Err(error) => Result.Err(error)
                    }
            }
        case Result.Ok(ToolPreparation.Completed(result)) =>
            Result.Ok(ToolInvocationResult.Completed(result))
        case Result.Ok(ToolPreparation.Denied(denial)) =>
            Result.Ok(ToolInvocationResult.Denied(denial))
    }
}

public func preparePipelineCall(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    call: ToolCall
): Result<PreparedToolInvocation> {
    match (pipeline.prepare(context, call)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(ToolPreparation.Ready(prepared)) =>
            match (prepareDirectOperation(pipeline, context, prepared)) {
                case Result.Ok(_) => Result.Ok(prepared)
                case Result.Err(error) => Result.Err(error)
            }
        case Result.Ok(ToolPreparation.NeedsApproval(_, _)) => Result.Err(AgentError(
            AgentErrorKind.PermissionDenied,
            "test.prepared_call_requires_approval",
            "test prepared-call helper requires a ready policy decision"
        ))
        case Result.Ok(ToolPreparation.Completed(_)) => Result.Err(AgentError(
            AgentErrorKind.Conflict,
            "test.prepared_call_already_completed",
            "test prepared-call helper received a completed operation"
        ))
        case Result.Ok(ToolPreparation.Denied(_)) => Result.Err(AgentError(
            AgentErrorKind.PermissionDenied,
            "test.prepared_call_denied",
            "test prepared-call helper received a denied operation"
        ))
    }
}

func prepareDirectOperation(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    prepared: PreparedToolInvocation
): Result<Unit> {
    pipeline.operationRuntime().prepareProgramSubOperation(
        prepared.operationId,
        context.runId,
        ItemId("sdk-direct-tool-call-" + prepared.operationId.value),
        prepared.operationPlan
    )
}
func executePreparedAndPersist(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    prepared: PreparedToolInvocation,
    persistResult: Bool
): Result<ToolInvocationResult> {
    let result = pipeline.executePrepared(context, prepared)
    if (!persistResult) { return result }
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            match (pipeline.afterResultPersisted(
                context,
                prepared.call.name,
                ToolInvocationResult.Completed(value)
            )) {
                case Result.Ok(_) => result
                case Result.Err(error) => Result.Err(error)
            }
        case _ => result
    }
}
