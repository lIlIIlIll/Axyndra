package agent_domain

import logical_json_payload as payload
import yjson.*
import yjson_support.*

// Source-compatible names are the SAME concrete objects in the neutral
// library. No wrapper budget, second bank, fresh grant or copied lease exists.
public type LogicalJsonPayloadError = payload.LogicalJsonPayloadError
public type LogicalJsonOwnerBudget = payload.LogicalJsonOwnerBudget
public type LogicalJsonFixedBufferReservation = payload.LogicalJsonFixedBufferReservation
public type LogicalJsonOwnerReservation = payload.LogicalJsonOwnerReservation
public type LogicalJsonProcessBudget = payload.LogicalJsonProcessBudget
public type LogicalJsonReservation = payload.LogicalJsonReservation
public type LogicalJsonReceiver = payload.LogicalJsonReceiver
public let LOGICAL_JSON_PAYLOAD_SCHEMA = payload.LOGICAL_JSON_PAYLOAD_SCHEMA
public let LOGICAL_JSON_CHUNK_BYTES = payload.LOGICAL_JSON_CHUNK_BYTES
public let LOGICAL_JSON_HARD_BYTES = payload.LOGICAL_JSON_HARD_BYTES

public func writeLogicalJsonPayload(window: String, sequence: Int64, messageType: String,
    source: String, maximum: Int64, check: () -> Unit, emit: (String, AgentValue) -> Unit): Unit {
    payload.writeLogicalJsonPayload(window, sequence, messageType, source, maximum, check, emit)
}

public func logicalJsonNodeCount(source: String): Int64 {
    payload.logicalJsonNodeCount(source)
}

public func logicalJsonWriteReservationBytes(value: AgentValue, maximum: Int64): Int64 {
    payload.logicalJsonWriteReservationBytes(value, maximum)
}

public func logicalJsonValueNodeCount(value: AgentValue): Int64 {
    payload.logicalJsonValueNodeCount(value)
}

public func logicalJsonEncodeHex(bytes: Array<Byte>): String {
    payload.logicalJsonEncodeHex(bytes)
}
