package agent_product

import agent_domain
import agent_extension_runtime
import agent_domain.LogicalJsonOwnerReservation
import agent_extension_runtime.reserveNativeControlMetadata

// DATA allocation only, from the existing process-wide Native payload bank.
// Call before constructing retained controls/closures. The actual consumer
// clears its aliases and joins its producers before closing this reservation.
// The existing floor, aggregate cap and derived-lease SUM are unchanged.
public func reserveProductControlMetadata113(bytes: Int64): LogicalJsonOwnerReservation {
    reserveNativeControlMetadata(bytes)
}

// Same original bank, scalar observation and fixed physical workspace only.
public func productControlMetadataUsage113(): (Int64, Int64) {
    agent_extension_runtime.nativeControlMetadataUsage113()
}

// The shared bank's product quota. Tests that drive the bank to its refusal
// point read this instead of restating the quota, so the quota is one fact.
public func productControlMetadataCapacity113(): Int64 {
    agent_extension_runtime.nativeControlMetadataCapacity113()
}

// Exact numeric observation of the same process-wide bank's fixed aggregate.
// Numeric only: no reservation, capacity change or authority escapes.
public func nativeControlMetadataCapacityReader173c(): Int64 {
    agent_extension_runtime.nativeControlMetadataCapacity113()
}
public func reserveProductObservationBuffer113(): agent_domain.LogicalJsonFixedBufferReservation {
    agent_extension_runtime.reserveNativeObservationBuffer()
}
