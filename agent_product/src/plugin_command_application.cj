package agent_product

import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Retained by the actual Application session from parser invocation until the
// canonical Direct result is consumed. It is not a Core model approval record.
class ApplicationPluginCommandControl {
    let scope: ProductPluginCommandScope
    let cancellation: CancellationSource
    private let owner: ProductDirectPreparationOwner
    private let product: ProductRuntime
    private let accepted: (ProductCommandProposal, ?ProductContinuationOwner) -> Result<Unit>
    private let lock = Mutex()
    private var closed = false
    private var proposal: ?ProductCommandProposal = None
    private var originalCommandHelpers180: Int64 = 0
    private var directCleanupAttempted180 = false

    init(product: ProductRuntime, scope: ProductPluginCommandScope, cancellation: CancellationSource,
        accepted: (ProductCommandProposal, ?ProductContinuationOwner) -> Result<Unit>) {
        this.product = product; this.scope = scope; this.cancellation = cancellation
        this.owner = ProductDirectPreparationOwner({ => scope.current() })
        this.accepted = accepted
    }
    func isClosed(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
    func enterOriginalCommandHelper180(): Bool {
        lock.lock()
        try {
            // Calls which enter after closure can only observe the existing
            // closed scalar state; they cannot run a Gateway continuation.
            if (closed) { return false }
            if (originalCommandHelpers180 == Int64.Max) { throw IllegalStateException("command helper count overflow") }
            originalCommandHelpers180++; true
        } finally { lock.unlock() }
    }
    func originalCommandHelperReturned180(entered: Bool): Bool {
        lock.lock()
        let (returned, probe) = try {
            if (entered) {
                if (originalCommandHelpers180 <= 0) { throw IllegalStateException("command helper returned without entry") }
                originalCommandHelpers180--
            }
            let complete = closed && originalCommandHelpers180 == 0
            let inspect = complete && !directCleanupAttempted180
            if (inspect) { directCleanupAttempted180 = true }
            (complete, inspect)
        } finally { lock.unlock() }
        // ApplicationSession calls this only AFTER its original whole invoke,
        // decide or cancel helper returned. SQL/physical proof is unchanged;
        // a failed proof keeps the original Gateway DATA frame charged.
        if (probe) { let _ = owner.closeAcknowledgement() }
        returned
    }
    func approval(): ?ApprovalRequest {
        let actual = match (owner.approval()) { case None => return None; case Some(value) => value }
        lock.lock()
        let selected: ?ProductCommandProposal = try { match (proposal) { case Some(value) => Some(scope.resolvedProposal(value)); case None => None } } finally { lock.unlock() }
        let control: ?AgentValue = match (selected) { case Some(value) => value.control(); case None => None }
        match (control) {
            case None => match (selected) {
                case Some(value) => if (value.binding.allowsControl()) {
                    Some(ApprovalRequest(actual.operationId, actual.callId, actual.toolName, actual.capability,
                        preview: objectValue([ValueField("operation", actual.preview),
                            ValueField(if (scope.preparationResolved()) { "host_user_control_status" } else { "host_user_control_pending" },
                                textValue(if (scope.preparationResolved()) { "this document operation does not change continuation permission" }
                                    else { "the final control will be selected from this canonical read and reviewed separately" })),
                            ValueField("command_input", value.call().arguments),
                            ValueField("command_proposal_digest", textValue(value.sourceDigest))]),
                        sessionId: actual.sessionId, argumentHash: actual.argumentHash, riskFlags: actual.riskFlags,
                        review: actual.review, metadata: actual.metadata, decisionSource: actual.decisionSource,
                        sessionApprovalAllowed: false))
                } else { Some(actual) }
                case None => Some(actual) }
            case Some(value) =>
                // Display-only wrapper: the retained owner authorizes its own
                // original Prepared. No preview/hash is accepted back from UI.
                Some(ApprovalRequest(actual.operationId, actual.callId, actual.toolName, actual.capability,
                    preview: objectValue([ValueField("operation", actual.preview),
                        ValueField("host_user_control", value), ValueField("command_proposal_digest", textValue(selected.getOrThrow().sourceDigest))]),
                    sessionId: actual.sessionId, argumentHash: actual.argumentHash, riskFlags: actual.riskFlags,
                    review: actual.review, metadata: actual.metadata, decisionSource: actual.decisionSource,
                    sessionApprovalAllowed: false))
        }
    }
    func invoke(route: String, arguments: String, noticeSink: ProductJavaScriptPluginNoticeSink): Result<ApplicationResponse> {
        match (product.invokeScopedPluginCommand(route, arguments, scope, noticeSink)) {
            case Result.Err(error) => close(); return Result.Err(error); case Result.Ok(_) => () }
        let selected = match (scope.take()) {
            case Result.Err(error) => close(); return Result.Err(error)
            case Result.Ok(None) => close(); return Result.Ok(ApplicationResponse(false))
            case Result.Ok(Some(value)) => value }
        lock.lock(); try { proposal = Some(selected) } finally { lock.unlock() }
        // The participant is a host-held actual-user capability. The plugin's
        // control object alone is merely a proposal and cannot construct one.
        let participant = match (product.pluginCommandParticipant(scope, selected)) {
            case Result.Err(error) => close(); return Result.Err(error); case Result.Ok(value) => value }
        consume(product.executePluginCommandProposal(scope, selected, owner, participant: participant))
    }
    func decide(operationId: String, decision: ApprovalDecision): Result<ApplicationResponse> {
        if (isClosed()) { return commandControlError("plugin.command_scope_closed") }
        lock.lock()
        let hasControl = try { match (proposal) { case Some(value) => value.binding.allowsControl(); case None => false } }
            finally { lock.unlock() }
        if (hasControl && match (decision) { case ApprovalDecision.ApproveSession => true; case _ => false }) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "approval.session_scope_forbidden",
                "a frozen user continuation control requires its own one-time approval")) }
        let result = owner.decide(operationId, decision)
        if (result.isError() && owner.approval().isSome()) {
            // A pure invalid-choice/mismatched-id error has not consumed the
            // retained review. Keep both the actual user scope and its token.
            return Result.Err(result.error().getOrThrow()) }
        consume(result)
    }
    func cancel(): Result<Unit> {
        let _ = cancellation.cancel()
        // During actual execution the same token immediately reaches the Run;
        // its executor owns settlement. At a retained review we must explicitly
        // settle that exact Prepared and the original parent before closing.
        if (owner.approval().isNone()) { return Result.Ok(()) }
        let cancelled = owner.cancel()
        let rejected = match (cancelled) { case Result.Ok(ToolInvocationResult.Denied(_)) => true; case _ => false }
        match (consume(cancelled)) {
            case Result.Err(error) => if (error.kind == AgentErrorKind.Cancelled || rejected) { Result.Ok(()) } else { Result.Err(error) }
            case Result.Ok(_) => Result.Ok(()) }
    }
    private func consume(result: Result<ToolInvocationResult>): Result<ApplicationResponse> {
        match (result) {
            case Result.Ok(ToolInvocationResult.NeedsApproval(approval)) =>
                // Cancellation can race publication after the executor's last
                // check. Never publish an approval backed by a cancelled caller.
                if (cancellation.token.isCancelled()) {
                    return consume(owner.cancel()) }
                Result.Ok(ApplicationResponse(false, approval: this.approval()))
            case Result.Ok(ToolInvocationResult.Completed(value)) =>
                try {
                    if (value.isError) {
                        return Result.Err(commandObservedToolError(value.output)) }
                    lock.lock()
                    let frozen: ?ProductCommandProposal = try { match (proposal) { case Some(value) => Some(scope.resolvedProposal(value)); case None => None } } finally { lock.unlock() }
                    match (frozen) {
                        case Some(selected) => match (product.acceptPluginCommandControl(scope, selected)) {
                            case Result.Err(error) => return Result.Err(error)
                            case Result.Ok(next) => match (accepted(selected, next)) {
                                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
                        case None => () }
                    let text = if (value.output.unifiedKind == ValueKind.Text) { value.output.text } else { encodeAgentValue(value.output) }
                    Result.Ok(ApplicationResponse(false, text: text))
                } finally { value.releasePayload(); close() }
            case Result.Ok(ToolInvocationResult.Denied(_)) =>
                close(); Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    "plugin.command_tool_denied", "command proposal did not receive canonical tool permission"))
            case Result.Err(error) => close(); Result.Err(error)
        }
    }
    private func close(): Unit {
        lock.lock()
        let first = try { if (closed) { false } else { closed = true; true } } finally { lock.unlock() }
        if (first) { scope.close(); cancellation.close() }
    }
}

// This output already crossed the canonical Tool result boundary. Preserve
// bounded diagnostic data without taking its fields as status or authority.
func commandObservedToolError(output: AgentValue): AgentError {
    let encoded = encodeAgentValue(output)
    let rendered = if (output.unifiedKind == ValueKind.Text) { output.text } else { encoded }
    let display = if (rendered.size <= 16384) { rendered } else { "observed output exceeds the inline preview; see its canonical ToolResult" }
    let observation = try {
        if (encoded.size <= 65536) { Some(OperationObservation(encoded)) }
        else { Some(OperationObservation(encodeAgentValue(objectValue([ValueField("omitted", boolValue(true)),
            ValueField("bytes", integerValue(encoded.size)), ValueField("sha256", textValue(modelPolicySha256Text(encoded))),
            ValueField("reason", textValue("canonical_tool_result_exceeds_inline_observation"))])))) }
    } catch (_: Exception) { Option<OperationObservation>.None }
    AgentError(AgentErrorKind.InvalidInput, "plugin.command_tool_failed",
        "the canonical command tool returned an error: " + display, observation: observation)
}
