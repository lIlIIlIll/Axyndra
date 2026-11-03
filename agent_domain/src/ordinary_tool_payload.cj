package agent_domain

import logical_json_payload as payload

public type OrdinaryToolPayloadLimits = payload.OrdinaryToolPayloadLimits
public let ORDINARY_TOOL_PAYLOAD_SCHEMA = payload.ORDINARY_TOOL_PAYLOAD_SCHEMA
public let ORDINARY_TOOL_PAYLOAD_INPUT_MAX = payload.ORDINARY_TOOL_PAYLOAD_INPUT_MAX
public let ORDINARY_TOOL_PAYLOAD_RESULT_MAX = payload.ORDINARY_TOOL_PAYLOAD_RESULT_MAX
public let ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX = payload.ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX

public func ordinaryToolPayloadLimitsFromValue(value: AgentValue): ?OrdinaryToolPayloadLimits {
    payload.ordinaryToolPayloadLimitsFromValue(value)
}

public func ordinaryToolPayloadOffer(): AgentValue {
    payload.ordinaryToolPayloadOffer()
}

public func validOrdinaryToolPayloadOffer(value: AgentValue): Bool {
    payload.validOrdinaryToolPayloadOffer(value)
}

public func validOrdinaryToolPayloadGrants(value: AgentValue): Bool {
    payload.validOrdinaryToolPayloadGrants(value)
}
