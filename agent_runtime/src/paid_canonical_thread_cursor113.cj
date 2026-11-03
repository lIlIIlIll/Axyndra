package agent_runtime

import agent_domain.*

// Complete paid DATA visits. Implementations retain the original row, end the
// actual SQL frame, and only then call consume. Neither ordinal nor callback
// identity is an execution/Source/current-context grant.
public interface PaidCanonicalThreadCursor113 {
    func requireBoundary(thread: ThreadId, revision: Int64, nextOrdinal: Int64,
        localGuard: () -> Result<Unit>): Result<Unit>
    func withOrdinal(thread: ThreadId, revision: Int64, nextOrdinal: Int64, ordinal: Int64,
        localGuard: () -> Result<Unit>, current: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemAliasCustody) -> Result<Unit>): Result<Unit>
}
