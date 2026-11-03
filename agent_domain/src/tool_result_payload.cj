package agent_domain

import std.sync.*

// Shared allocation ownership only, with no source or execution authority.
// Result wrappers retain the same lease. The terminal consumer releases it
// after canonical persistence/output consumption, including every error exit.
public class ToolResultPayloadLease {
    private let lock = Mutex()
    private var released = false
    private let release: () -> Unit
    public init(release: () -> Unit) { this.release = release }
    public func close(): Unit {
        lock.lock()
        let owned = try { if (released) { false } else { released = true; true } } finally { lock.unlock() }
        if (owned) { release() }
    }
}
public func releaseToolInvocationPayload(value: Result<ToolInvocationResult>): Unit {
    match (value) { case Result.Ok(ToolInvocationResult.Completed(result)) => result.releasePayload(); case _ => () }
}
