package agent_domain

import logical_json_payload as payload

public let CONTENT_PAYLOAD_SCHEMA = payload.CONTENT_PAYLOAD_SCHEMA
public let CONTENT_PAYLOAD_INPUT_BYTES = payload.CONTENT_PAYLOAD_INPUT_BYTES
public let CONTENT_PAYLOAD_RESULT_BYTES = payload.CONTENT_PAYLOAD_RESULT_BYTES
public let CONTENT_PAYLOAD_MESSAGE_BYTES = payload.CONTENT_PAYLOAD_MESSAGE_BYTES

public func contentPayloadLimitsValue(): AgentValue {
    payload.contentPayloadLimitsValue()
}

public func validContentPayloadLimits(value: AgentValue): Bool {
    payload.validContentPayloadLimits(value)
}
