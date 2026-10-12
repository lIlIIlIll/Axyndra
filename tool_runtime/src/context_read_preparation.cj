package tool_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Trusted adapter callbacks are attached to the actual catalog registration.
// The request remains powerless data until the current Runtime, read policy,
// normal approval and canonical Operation handoff have all succeeded.
public type ToolPreparationReadResolver = (ToolInvocationContext, ToolCall) -> Result<?ToolPreparationRead>
public type ToolPreparationReadBoundary = (ToolInvocationContext, AgentValue) -> Result<Unit>
public type ToolPreparationReadContinuation = (ToolInvocationContext, Array<ContextReadFact>) -> Result<AgentValue>

public class ToolPreparationRead {
    public let ownerNamespace: String
    public let packageDigest: String
    public let configurationDigest: String
    private let requestJson: String
    private let continuation: ToolPreparationReadContinuation
    private let boundary: ?ToolPreparationReadBoundary
    public let sequence: ?ToolPreparationReadSequence

    public init(ownerNamespace: String, packageDigest: String, configurationDigest: String,
        request: AgentValue, continuation: ToolPreparationReadContinuation,
        boundary!: ?ToolPreparationReadBoundary = None, sequence!: ?ToolPreparationReadSequence = None) {
        let _ = ContextReadOrigin(ownerNamespace, packageDigest, configurationDigest,
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0000000000000000000000000000000000000000000000000000000000000000", "validation", "")
        if (request.unifiedKind != ValueKind.Object) { throw IllegalArgumentException("preparation read request must be an object") }
        let text = stringifyUnifiedJson(request)
        let _ = parseUnifiedJson(text, maxBytes: 65536)
        this.ownerNamespace = ownerNamespace; this.packageDigest = packageDigest
        this.configurationDigest = configurationDigest; this.requestJson = text; this.continuation = continuation; this.boundary = boundary
        this.sequence = sequence
    }

    // This callback is held only by the actual host descriptor's continuation.
    // It is never decoded from a plugin field or a durable origin DTO.
    public func validateBoundary(context: ToolInvocationContext, arguments: AgentValue): Result<Unit> {
        let view = context.beginInvocationView159()
        try { validateBoundaryScope159(view, arguments) } finally { view.endInvocationView159() }
    }

    private func validateBoundaryScope159(context: ToolInvocationContext, arguments: AgentValue): Result<Unit> {
        match (boundary) {
            case Some(check) => try { check(context, arguments) }
                catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    "context.read_boundary_changed", "captured resource boundary is unavailable")) }
            case None => Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "context.read_boundary_missing", "resource executor requires its original host boundary"))
        }
    }

    public func request(): AgentValue { parseUnifiedJson(requestJson, maxBytes: 65536) }
    // Only Core calls this with facts reread from the Operation port. This
    // callback cannot give those DTOs execution authority; final Store checks
    // every reference again against the original canonical parent.
    public func complete(context: ToolInvocationContext, facts: Array<ContextReadFact>): Result<AgentValue> {
        let view = context.beginInvocationView159()
        try { completeScope159(view, facts) } finally { view.endInvocationView159() }
    }

    private func completeScope159(context: ToolInvocationContext, facts: Array<ContextReadFact>): Result<AgentValue> {
        try {
            let value = match (continuation(context, facts.clone())) {
                case Result.Ok(item) => item; case Result.Err(error) => return Result.Err(error) }
            if (value.unifiedKind != ValueKind.Object) { throw IllegalArgumentException("continued input must be an object") }
            Result.Ok(parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608))
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.InvalidInput,
            "context.read_continuation_invalid", "read preparation did not produce a bounded immutable tool input")) }
    }
}
