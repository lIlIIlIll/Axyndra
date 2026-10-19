package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// Explicit operator transport bounds. They grant neither an operation nor a
// byte write. Store must compare them to the completed startup's exact grant.
// The physical Native v2 frame ceiling is unchanged; Tool and Pi reject this
// extension. transfer_sequence is framing order, never a model Attempt.
public class ServicePayloadLimits {
    public let maxMessageBytes: Int64
    public let maxInputBytes: Int64
    public let maxPrepareBytes: Int64
    public let maxResultBytes: Int64
    public let maxWriteBytes: Int64
    init(message: Int64, input: Int64, prepared: Int64, result: Int64, write: Int64) {
        maxMessageBytes = message; maxInputBytes = input; maxPrepareBytes = prepared
        maxResultBytes = result; maxWriteBytes = write
    }
    public func toValue(): AgentValue {
        objectValue([ValueField("version", integerValue(1)), ValueField("max_message_bytes", integerValue(maxMessageBytes)),
            ValueField("max_input_bytes", integerValue(maxInputBytes)), ValueField("max_prepare_bytes", integerValue(maxPrepareBytes)),
            ValueField("max_result_bytes", integerValue(maxResultBytes)), ValueField("max_write_bytes", integerValue(maxWriteBytes))])
    }
}

public func parseServicePayloadLimits(value: AgentValue): Result<ServicePayloadLimits> {
    if (!httpIntentExactFields(value, ["version", "max_message_bytes", "max_input_bytes", "max_prepare_bytes", "max_result_bytes", "max_write_bytes"])) {
        return httpIntentError("service.payload_limits_invalid", "logical payload limits require an exact versioned operator profile")
    }
    try {
        func number(name: String): Int64 {
            let item = value.field(name).getOrThrow()
            if (item.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("invalid payload limit") }
            let result = Int64.parse(item.asNumberText())
            if (result.toString() != item.asNumberText()) { throw IllegalArgumentException("noncanonical payload limit") }
            result
        }
        let message = number("max_message_bytes"); let input = number("max_input_bytes")
        let prepared = number("max_prepare_bytes"); let result = number("max_result_bytes"); let write = number("max_write_bytes")
        if (number("version") != 1 || message < 1048576 || message > 16777216 || input < 1 || input > 4194304 ||
            prepared < 1 || prepared > 8388608 || result < 1 || result > 8388608 || write < 1 || write > 4194304 ||
            input + 262144 > message || prepared + 262144 > message || result + 262144 > message || write * 2 + 65536 > prepared) {
            return httpIntentError("service.payload_limits_invalid", "logical payload profile exceeds bounded memory or durable envelopes")
        }
        Result.Ok(ServicePayloadLimits(message, input, prepared, result, write))
    } catch (_: Exception) { httpIntentError("service.payload_limits_invalid", "logical payload limits must be bounded canonical integers") }
}

public func servicePayloadLimits(container: AgentValue): Result<?ServicePayloadLimits> {
    match (container.field("payload_limits")) {
        case None => Result.Ok(None)
        case Some(value) =>
            if (container.field("protocol_limits").isNone() || !serviceProtocolLimits(container).isOk() ||
                !serviceProtocolLimits(container).value().getOrThrow().isExplicit) {
                return httpIntentError("service.payload_limits_invalid", "logical payload limits require an explicit physical service profile")
            }
            match (parseServicePayloadLimits(value)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(limits) => Result.Ok(Some(limits))
        }
    }
}
public func sameServicePayloadLimits(grant: AgentValue, binding: AgentValue): Bool {
    match ((grant.field("payload_limits"), binding.field("payload_limits"))) {
        case (None, None) => true
        case (Some(left), Some(right)) => parseServicePayloadLimits(left).isOk() && parseServicePayloadLimits(right).isOk() &&
            canonicalAgentValue(left) == canonicalAgentValue(right)
        case _ => false
    }
}
