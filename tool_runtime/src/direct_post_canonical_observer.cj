package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*

// A concrete installed executor explicitly opts into a Direct data projection.
// Ordinary afterResultPersisted remains unchanged and is not globally enabled.
public interface DirectPostCanonicalToolObserver {
    func afterDirectResultPersisted(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): Result<Unit>
}

public class DirectPostCanonicalObserverCapture {
    let context: ToolInvocationContext
    let prepared: PreparedToolInvocation
    let executor: Object
    let observer: DirectPostCanonicalToolObserver
    private let lock = Mutex()
    private var active = true
    private var consumed = false
    init(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        executor: Object, observer: DirectPostCanonicalToolObserver) {
        this.context = context; this.prepared = prepared; this.executor = executor; this.observer = observer
    }
    func consume(action: () -> Result<Unit>): Result<Unit> {
        lock.lock(); try {
            if (!active || consumed) { return directPostCanonicalObserverFailure("tool.direct_projection_capture_consumed") }
            consumed = true; action()
        } finally { lock.unlock() }
    }
    func consumeOwned113(action: () -> OwnedPostCanonicalObserverDispatch113): OwnedPostCanonicalObserverDispatch113 {
        lock.lock(); try {
            if (!active || consumed) {
                return OwnedPostCanonicalObserverDispatch113.Existing(
                    directPostCanonicalObserverFailure("tool.direct_projection_capture_consumed")) }
            consumed = true; action()
        } finally { lock.unlock() }
    }
    public func close(): Unit { lock.lock(); try { active = false } finally { lock.unlock() } }
}

func directPostCanonicalObserverFailure(code: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "post-canonical observer differs from the actual frozen executor or invocation"))
}
