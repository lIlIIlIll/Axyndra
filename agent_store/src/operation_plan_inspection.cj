package agent_store

import agent_domain.*

// Read-only equality against the Store's own canonical serialization. This
// exposes neither a decoder nor authority to create or modify an Operation.
public func storedOperationPlanMatches(encoded: String, expected: NormalizedOperationPlan): Bool {
    encoded == encodeOperationPlan(expected)
}

// The caller already holds an actual document-commit proof and its same-Tx
// row. This predicate checks frozen data; it cannot mint an operation source.
public func storedOperationArgumentsMatch(encoded: String, expected: String): Bool {
    try { canonicalAgentValue(decodeOperationPlan(encoded).canonicalArguments) == expected }
    catch (_: Exception) { false }
}
