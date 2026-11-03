package tool_runtime

import agent_domain.*

// Only the actual Tools private publication factory can mint Waiting. A
// final Completed still belongs to the ORIGINAL parent and carries its real
// paid payload lease. Core commits its single canonical Receipt/ToolResult.
public enum OwnedToolPipelineProgress {
    Completed(Result<ToolInvocationResult>)
    // The actual final witness/output was verified. Core must persist/ACK
    // this SAME known result before reporting physical settlement failure.
    // The original Host collector still owns the unacknowledged resources.
    | CompletedWithDebt(Result<ToolInvocationResult>,AgentError)
    | Waiting(OwnedToolExecutionPublication)
    | Retained(OwnedToolRetainedParentExecution)
    | RetainedWithDebt(OwnedToolRetainedParentExecution,AgentError)
    | FailedRetained(OwnedToolRetainedFailureExecution,AgentError)
}
