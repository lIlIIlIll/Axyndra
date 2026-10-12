package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Trusted host continuation only. The Read variant still enters the same
// canonical preparation/policy/approval/slot/Receipt path; it is not a grant.
public enum ContextReadNext {
    Read(ToolPreparationRead)
    | Ready(InvocationContextProjection)
}

public class ContextReadSequence {
    public let maximumReads: Int64
    private let advanceFn: (ToolInvocationContext, Array<ContextReadFact>) -> Result<ContextReadNext>
    private let transitionFn: ?(ToolPreparationRead, ToolPreparationRead) -> Result<Unit>
    public init(maximumReads: Int64,
        advance: (ToolInvocationContext, Array<ContextReadFact>) -> Result<ContextReadNext>,
        transition!: ?(ToolPreparationRead, ToolPreparationRead) -> Result<Unit> = None) {
        if (maximumReads < 1 || maximumReads > 8) { throw IllegalArgumentException("context read sequence requires 1..8 stages") }
        this.maximumReads = maximumReads; this.advanceFn = advance; this.transitionFn = transition
    }
    public func advance(context: ToolInvocationContext, facts: Array<ContextReadFact>): Result<ContextReadNext> {
        advanceFn(context, facts.clone())
    }
    // Trusted composition may select the next exact frozen provider. Every
    // returned read still obtains its own actual Source, policy and Receipt.
    // The default retains the original same-owner/package restriction.
    func validateTransition(current: ToolPreparationRead, next: ToolPreparationRead): Result<Unit> {
        match (transitionFn) {
            case Some(validate) => try { validate(current, next) }
                catch (_: Exception) { readUpdateError("context.read_update_next_invalid") }
            case None => if (current.ownerNamespace == next.ownerNamespace && current.packageDigest == next.packageDigest) {
                Result.Ok(()) } else { readUpdateError("context.read_update_next_invalid") }
        }
    }
}
