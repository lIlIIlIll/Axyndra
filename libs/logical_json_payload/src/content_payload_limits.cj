package logical_json_payload

import yjson.*
import yjson_support.*

// An allocation/transport profile only. It never supplies an Operation, read
// capability, approval, Service callback, or filesystem access. The input is
// one existing 4 MiB ContextRead fact plus the existing 192 KiB pure query and
// a 64 KiB identity/fact-link envelope. Output stays at the Context snapshot
// codec's existing 4 MiB ceiling; its final projection must still validate.
public let CONTENT_PAYLOAD_CONTEXT_SNAPSHOT_BYTES: Int64 = 4194304
public let CONTENT_PAYLOAD_SCHEMA = "axyndra.content-payload/v1"
public let CONTENT_PAYLOAD_INPUT_BYTES: Int64 = CONTENT_PAYLOAD_CONTEXT_SNAPSHOT_BYTES + 262144
public let CONTENT_PAYLOAD_RESULT_BYTES: Int64 = CONTENT_PAYLOAD_CONTEXT_SNAPSHOT_BYTES
public let CONTENT_PAYLOAD_MESSAGE_BYTES: Int64 = CONTENT_PAYLOAD_INPUT_BYTES + 65536

public func contentPayloadLimitsValue(): AgentValue {
    objectValue([ValueField("schema", textValue(CONTENT_PAYLOAD_SCHEMA)),
        ValueField("max_message_bytes", integerValue(CONTENT_PAYLOAD_MESSAGE_BYTES)),
        ValueField("max_input_bytes", integerValue(CONTENT_PAYLOAD_INPUT_BYTES)),
        ValueField("max_result_bytes", integerValue(CONTENT_PAYLOAD_RESULT_BYTES))])
}
public func validContentPayloadLimits(value: AgentValue): Bool {
    httpIntentExactFields(value, ["schema", "max_message_bytes", "max_input_bytes", "max_result_bytes"]) &&
        canonicalAgentValue(value) == canonicalAgentValue(contentPayloadLimitsValue())
}
