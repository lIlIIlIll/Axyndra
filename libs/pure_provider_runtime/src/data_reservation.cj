package pure_provider_runtime

import logical_json_payload.*

// Pure retained data uses the same process-wide accounting owner as framing
// and results. This is allocation only: no file, service, source or grant.
public func reservePurePolicyData(bytes: Int64): LogicalJsonOwnerReservation {
    providerPayloadOwner.acquire(bytes)
}

// Raw retained slots are not decoded ordinary logical messages. Begin must
// validate all bounded lengths, then grow this same pool owner to the explicit
// raw/input peak before retaining bytes. Ordinary acquire(bytes)*8 is unchanged.
public func reservePurePolicyRawData(): LogicalJsonOwnerReservation {
    providerPayloadOwner.acquire(1)
}
