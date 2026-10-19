package tool_runtime

import agent_domain.*
import agent_runtime.*

// Local execution facts, never a Root/Grant, plugin frame, Bool verifier or
// authority callback. Only the validating factory below creates this proof.
public class ToolExecutionCancellationEvidence {
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let error: AgentError
    private let token: CancellationToken
    private let runId: String
    private let threadId: String
    private let epoch: Int64
    private let operationId: String
    private let callId: String
    private let reason: CancellationReason

    init(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        error: AgentError, token: CancellationToken, reason: CancellationReason) {
        this.context = context; this.prepared = prepared; this.error = error
        this.token = token; this.reason = reason
        runId = context.runId.value; threadId = context.sessionId.value
        epoch = context.epoch; operationId = prepared.operationId.value; callId = prepared.call.callId
    }

    func matches(context: ToolInvocationContext, prepared: PreparedToolInvocation, error: AgentError): Bool {
        if (!refEq(this.context, context) || !refEq(this.prepared, prepared) || !refEq(this.error, error) ||
            error.kind != AgentErrorKind.Cancelled || runId != context.runId.value || threadId != context.sessionId.value ||
            epoch != context.epoch || operationId != prepared.operationId.value || callId != prepared.call.callId ||
            prepared.source.runId.value != runId || prepared.source.sessionId.value != threadId ||
            prepared.source.epoch != epoch || !token.isCancelled()) { return false }
        match (token.reason()) {
            case Some(current) => current.kind == reason.kind && current.code == reason.code &&
                current.message == reason.message && current.cancelledAtMillis == reason.cancelledAtMillis &&
                current.code == error.code && current.message == error.message
            case None => false
        }
    }
}

// The trusted local adapter supplies its actual captured read-only token and
// exact returned Err. A decoded plugin error/code alone cannot form evidence.
public func observeToolExecutionCancellation(context: ToolInvocationContext, prepared: PreparedToolInvocation,
    error: AgentError, token: CancellationToken): ?ToolExecutionCancellationEvidence {
    if (error.kind != AgentErrorKind.Cancelled || prepared.source.runId.value != context.runId.value ||
        prepared.source.sessionId.value != context.sessionId.value || prepared.source.epoch != context.epoch ||
        prepared.source.operationRoot.isNone() || !token.isCancelled()) { return None }
    let reason = match (token.reason()) { case Some(value) => value; case None => return None }
    if (reason.code != error.code || reason.message != error.message) { return None }
    Some(ToolExecutionCancellationEvidence(context, prepared, error, token, reason))
}

public class ToolExecutionOutcome {
    public let result: Result<ToolResult>
    private let cancellationEvidence: ?ToolExecutionCancellationEvidence

    public init(result: Result<ToolResult>, cancellationEvidence!: ?ToolExecutionCancellationEvidence = None) {
        this.result = result; this.cancellationEvidence = cancellationEvidence
    }

    func provesCancellation(context: ToolInvocationContext, prepared: PreparedToolInvocation, error: AgentError): Bool {
        match (result) {
            case Result.Err(actual) => if (!refEq(actual, error)) { return false }
            case Result.Ok(_) => return false
        }
        match (cancellationEvidence) {
            case Some(value) => value.matches(context, prepared, error)
            case None => false
        }
    }
}
