package tool_runtime

import agent_domain.*
import std.sync.*

// Explicit actual data custody only; this never grants Source or approval.
// Tools performs its complete private Prepared/source/reference walk and
// pays the actual derived lease BEFORE any paid publication escapes.
public interface OwnedPendingPreparedAliasCustody {
    func retainPendingPreparedAliases(parent: PreparedToolInvocation,
        child: PreparedToolInvocation): Result<LogicalJsonOwnerReservation>
    // Unlock only. The next real Session must first pay the complete next
    // ledger before the old metadata/physical owner acknowledges retirement.
    func pendingPreparedAliasesRetired(retirement: OwnedPendingPreparedAliasRetirement): Result<Unit>
}

// The minimum contract deliberately has NO issuer. The successor actual
// Tools mutable holder may add its private issuer only after all published
// Prepared/call/plan/approval/source references and escaper frames retire.
// Historical immutable Waiting continuations cannot obtain this token.
// Neither a wire Bool/ID nor a Source/Receipt can construct it.
public class OwnedPendingPreparedAliasRetirement {
    private let custody: LiveToolExecutionCustody
    private init(custody: LiveToolExecutionCustody) { this.custody = custody }
    private let lock = Mutex()
    private var consumed = false
    // Successful exact-custody matching consumes this private token once.
    // A token from an earlier Waiting cannot unlock a later same-custody gate.
    // Failure after consumption remains closed debt; it never retries effects.
    public func matches(actual: LiveToolExecutionCustody): Bool {
        lock.lock()
        try {
            if (consumed || !sameLiveToolExecutionCustody(custody, actual)) { return false }
            consumed = true; true
        } finally { lock.unlock() }
    }
}
