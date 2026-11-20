package agent_runtime

import std.sync.*

// A receiver may compare only its own stored bytes. Source, handoff, lane,
// epoch and receipt remain the operation port's separate transaction checks.
public class PluginChildPlanMatch {
    private let lock = Mutex()
    private var expected: ?String
    init(encoded: ?String) { expected = encoded }

    public func hasCandidate(): Bool {
        lock.lock(); try { expected.isSome() } finally { lock.unlock() }
    }
    public func matchesStored(stored: String): Bool {
        lock.lock()
        try { match (expected) { case Some(value) => value == stored; case None => false } }
        finally { lock.unlock() }
    }
    func revoke(): Unit { lock.lock(); try { expected = None<String> } finally { lock.unlock() } }
}

// The frame is immutable data, not an authorization or a validation callback.
// A retained handle loses the only reference it could read when the scope ends.
public func withPluginChildPlanBytes<T>(encoded: ?String, body: (PluginChildPlanMatch) -> T): T {
    let proof = PluginChildPlanMatch(encoded)
    try { body(proof) } finally { proof.revoke() }
}
