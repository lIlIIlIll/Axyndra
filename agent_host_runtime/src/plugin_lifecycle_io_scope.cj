package agent_host_runtime

import agent_domain.*
import std.sync.*

// One actual read/write call, never a session permission. The owner's existing
// monitor checks its deadline; callbacks run outside both scope and owner locks.
public class HostLifecycleIoScope {
    private let lock = Mutex()
    private let deadline: Int64
    private let cancelAction: () -> Unit
    private var closed = false
    private var cancelled = false
    private var registration: ?CancellationRegistration = None
    public init(deadline: Int64, cancelAction: () -> Unit) {
        this.deadline = deadline; this.cancelAction = cancelAction
    }
    public func arm(token: CancellationToken): Unit {
        let value = token.onCancel({ _ => cancel() })
        lock.lock()
        let dispose = try { if (!closed) { registration = Some(value) }; closed } finally { lock.unlock() }
        if (dispose) { value.dispose() }
        checkDeadline()
    }
    public func checkDeadline(): Unit { if (deadline > 0 && agentUtcMillis() >= deadline) { cancel() } }
    private func cancel(): Unit {
        lock.lock()
        let notify = try {
            if (closed || cancelled) { false } else { cancelled = true; true }
        } finally { lock.unlock() }
        if (notify) { cancelAction() }
    }
    public func finish(): Bool {
        lock.lock()
        let (value, wasCancelled) = try { closed = true; (registration, cancelled) } finally { lock.unlock() }
        match (value) { case Some(found) => found.dispose(); case None => () }
        wasCancelled
    }
    public func isCancelled(): Bool {
        checkDeadline()
        lock.lock(); try { cancelled } finally { lock.unlock() }
    }
}
