package tool_runtime

import agent_domain.*
import agent_runtime.*

// These optional callbacks return owned DATA after the original canonical
// result and Receipt already exist. None preserves the one original callback;
// an owned value/failure never invokes that old callback a second time.
public interface PaidPreparedPostCanonicalToolObserver113 {
    func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit>
}
public interface PaidDirectPostCanonicalToolObserver113 {
    func afterDirectResultPersistedOwned113(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit>
}

// The legacy Result remains explicit: it is never mistaken for an owned
// failure, and a None executor response is not an instruction to reconsume
// a Direct capture that already ran its original callback.
public enum OwnedPostCanonicalObserverDispatch113 {
    Existing(Result<Unit>) | Owned(OwnedFailureDataOutcome113<Unit>)
}
