package logical_json_payload

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let ORDINARY_TOOL_PAYLOAD_SCHEMA = "axyndra.ordinary-tool-payload/v1"
public let ORDINARY_TOOL_PAYLOAD_INPUT_MAX: Int64 = 2097152
public let ORDINARY_TOOL_PAYLOAD_RESULT_MAX: Int64 = 1114112
public let ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX: Int64 = 2162688

// Allocation/transport data, never an execution grant. Product selects this
// immutable profile from the operator's exact installed contribution binding.
public class OrdinaryToolPayloadLimits {
    public let contribution: String
    public let maxInputBytes: Int64
    public let maxResultBytes: Int64
    public let maxServiceResponseBytes: Int64
    public let maxMessageBytes: Int64
    public init(contribution: String, maxInputBytes!: Int64 = ORDINARY_TOOL_PAYLOAD_INPUT_MAX,
        maxResultBytes!: Int64 = ORDINARY_TOOL_PAYLOAD_RESULT_MAX,
        maxServiceResponseBytes!: Int64 = ORDINARY_TOOL_PAYLOAD_RESULT_MAX,
        maxMessageBytes!: Int64 = ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX) {
        if (!channelIntentIdentifier(contribution) || maxInputBytes < 1 || maxInputBytes > ORDINARY_TOOL_PAYLOAD_INPUT_MAX ||
            maxResultBytes < 1 || maxResultBytes > ORDINARY_TOOL_PAYLOAD_RESULT_MAX ||
            maxServiceResponseBytes < 1 || maxServiceResponseBytes > ORDINARY_TOOL_PAYLOAD_RESULT_MAX ||
            maxMessageBytes < max(maxInputBytes, max(maxResultBytes, maxServiceResponseBytes)) + 4096 ||
            maxMessageBytes > ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX) {
            throw IllegalArgumentException("ordinary Tool payload limits are outside the host ceiling")
        }
        this.contribution = contribution; this.maxInputBytes = maxInputBytes; this.maxResultBytes = maxResultBytes
        this.maxServiceResponseBytes = maxServiceResponseBytes; this.maxMessageBytes = maxMessageBytes
    }
    public func value(): AgentValue {
        objectValue([ValueField("schema", textValue(ORDINARY_TOOL_PAYLOAD_SCHEMA)),
            ValueField("contribution", textValue(contribution)), ValueField("max_input_bytes", integerValue(maxInputBytes)),
            ValueField("max_result_bytes", integerValue(maxResultBytes)), ValueField("max_service_response_bytes", integerValue(maxServiceResponseBytes)),
            ValueField("max_message_bytes", integerValue(maxMessageBytes))])
    }
}
public func ordinaryToolPayloadLimitsFromValue(value: AgentValue): ?OrdinaryToolPayloadLimits {
    if (!httpIntentExactFields(value, ["schema", "contribution", "max_input_bytes", "max_result_bytes", "max_service_response_bytes", "max_message_bytes"]) ||
        httpIntentText(value, "schema") != ORDINARY_TOOL_PAYLOAD_SCHEMA) { return None }
    try {
        let parsed = OrdinaryToolPayloadLimits(httpIntentText(value, "contribution"),
            maxInputBytes: readonlyDelegationInteger(value, "max_input_bytes"), maxResultBytes: readonlyDelegationInteger(value, "max_result_bytes"),
            maxServiceResponseBytes: readonlyDelegationInteger(value, "max_service_response_bytes"), maxMessageBytes: readonlyDelegationInteger(value, "max_message_bytes"))
        if (canonicalAgentValue(parsed.value()) != canonicalAgentValue(value)) { return None }
        Some(parsed)
    } catch (_: Exception) { None }
}
public func ordinaryToolPayloadOffer(): AgentValue {
    objectValue([ValueField("schema", textValue(ORDINARY_TOOL_PAYLOAD_SCHEMA)),
        ValueField("max_input_bytes", integerValue(ORDINARY_TOOL_PAYLOAD_INPUT_MAX)),
        ValueField("max_result_bytes", integerValue(ORDINARY_TOOL_PAYLOAD_RESULT_MAX)),
        ValueField("max_service_response_bytes", integerValue(ORDINARY_TOOL_PAYLOAD_RESULT_MAX)),
        ValueField("max_message_bytes", integerValue(ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX))])
}
public func validOrdinaryToolPayloadOffer(value: AgentValue): Bool {
    httpIntentExactFields(value, ["schema", "max_input_bytes", "max_result_bytes", "max_service_response_bytes", "max_message_bytes"]) &&
        canonicalAgentValue(value) == canonicalAgentValue(ordinaryToolPayloadOffer())
}
public func validOrdinaryToolPayloadGrants(value: AgentValue): Bool {
    if (value.unifiedKind != ValueKind.List || value.items.size > 32) { return false }
    let seen = HashSet<String>()
    for (entry in value.items) {
        let profile = match (ordinaryToolPayloadLimitsFromValue(entry)) { case Some(item) => item; case None => return false }
        if (seen.contains(profile.contribution)) { return false }; seen.add(profile.contribution)
    }
    true
}
