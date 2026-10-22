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
    func matchesReturned(prepared: PreparedToolInvocation, error: AgentError): Bool {
        // The Pipeline validated the exact executing context before publishing
        // this returned observation. Its temporary invocation view is now
        // retired; terminal consumption uses only the original captured facts.
        if (!refEq(this.prepared, prepared) || !refEq(this.error, error) ||
            error.kind != AgentErrorKind.Cancelled || operationId != prepared.operationId.value ||
            callId != prepared.call.callId || prepared.source.runId.value != runId ||
            prepared.source.sessionId.value != threadId || prepared.source.epoch != epoch || !token.isCancelled()) { return false }
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
    private let diagnostic: AgentValue

    public init(result: Result<ToolResult>, cancellationEvidence!: ?ToolExecutionCancellationEvidence = None,
        diagnostic!: AgentValue = nullValue()) {
        this.result = result; this.cancellationEvidence = cancellationEvidence; this.diagnostic = diagnostic
    }
    func returnedObservation(context: ToolInvocationContext, prepared: PreparedToolInvocation): ReturnedToolExecutionObservation {
        let evidence: ?ToolExecutionCancellationEvidence = match (result) {
            case Result.Err(error) => if (provesCancellation(context, prepared, error)) { cancellationEvidence } else { None }
            case Result.Ok(_) => None
        }
        let reason = context.cancellation.reason()
        let reasonCategory = match (reason) {
            case Some(value) => if (value.code == "run.parent_cancelled") { "run.parent_cancelled" }
                else if (value.code == "run.cancelled") { "run.cancelled" } else { "other" }
            case None => "none"
        }
        let returnedCancelled = match (result) { case Result.Err(error) => error.kind == AgentErrorKind.Cancelled; case Result.Ok(_) => false }
        let returnedCauseMatches = match (result) {
            case Result.Err(error) => match (reason) {
                case Some(value) => value.code == error.code && value.message == error.message
                case None => false }
            case Result.Ok(_) => false
        }
        ReturnedToolExecutionObservation(result, evidence, objectValue([
            ValueField("evidence_provided", boolValue(cancellationEvidence.isSome())),
            ValueField("evidence_matched_context", boolValue(evidence.isSome())),
            ValueField("context_cancelled", boolValue(context.cancellation.isCancelled())),
            ValueField("context_cause_category", textValue(reasonCategory)),
            ValueField("returned_cancelled", boolValue(returnedCancelled)),
            ValueField("returned_cause_matches", boolValue(returnedCauseMatches)),
            ValueField("executor_data", diagnostic)
            , ValueField("factory_source_matches_context", boolValue(prepared.source.runId.value == context.runId.value &&
                prepared.source.sessionId.value == context.sessionId.value && prepared.source.epoch == context.epoch))
            , ValueField("factory_operation_root_present", boolValue(prepared.source.operationRoot.isSome()))
        ]))
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

// Only the canonical Pipeline publishes this after the exact synchronous
// executor returned and its evidence matched the actual executing context.
// It is terminal observation DATA, not Source, IO permission or cleanup ACK.
public class ReturnedToolExecutionObservation {
    private let result: Result<ToolResult>
    private let cancellationEvidence: ?ToolExecutionCancellationEvidence
    private let diagnostic: AgentValue
    init(result: Result<ToolResult>, evidence: ?ToolExecutionCancellationEvidence, diagnostic: AgentValue) {
        this.result = result; cancellationEvidence = evidence; this.diagnostic = diagnostic
    }
    public func provesReturnedCancellation(prepared: PreparedToolInvocation, error: AgentError): Bool {
        match (result) {
            case Result.Err(actual) => if (!refEq(actual, error)) { return false }
            case Result.Ok(_) => return false
        }
        match (cancellationEvidence) {
            case Some(value) => value.matchesReturned(prepared, error)
            case None => false
        }
    }
    public func returnedErrorDiagnostic(error: AgentError): AgentValue {
        let sameError = match (result) { case Result.Err(actual) => refEq(actual, error); case Result.Ok(_) => false }
        objectValue([ValueField("observation_present", boolValue(true)),
            ValueField("exact_returned_error", boolValue(sameError)), ValueField("returned_data", diagnostic)])
    }
}
