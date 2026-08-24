package agent_cli

import std.overflow.*

// Stable digest shared by plan-review clients and the product session.
public func planReviewHash(value: String): String {
    // FNV-1a intentionally wraps on overflow; checked UInt64 arithmetic
    // would throw OverflowException on any non-trivial content.
    var hash: UInt64 = 1469598103934665603
    for (byte in value.toArray()) {
        hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211)
    }
    hash.toString()
}
