package agent_runtime

import agent_domain.*
import std.sync.*

// Invocation-local data-projection loan. It grants no execution, Source,
// permission, rewind cut or physical release. Only the actual Runtime mints it.
public class DirectPostCanonicalProjectionBoundary {
    public let source: DirectToolCallRef
    public let budget: ExecutionBudget
    private let lock = Mutex()
    private var active = true
    private var consumed = false
    private var action: ?((() -> Result<Unit>) -> Result<Unit>)
    init(source: DirectToolCallRef, budget: ExecutionBudget,
        action: (() -> Result<Unit>) -> Result<Unit>) {
        this.source = source; this.budget = budget; this.action = Some(action)
    }
    public func consume(consumer: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (!active || consumed || action.isNone()) {
                return directPostCanonicalProjectionFailure("runtime.projection_boundary_consumed") }
            consumed = true
            action.getOrThrow()(consumer)
        } finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock(); try { active = false; action = None<((() -> Result<Unit>) -> Result<Unit>)> }
        finally { lock.unlock() }
    }
}

func directPostCanonicalProjectionFailure(code: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "post-canonical data projection lost its current physical Run boundary"))
}
