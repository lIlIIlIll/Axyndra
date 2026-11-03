package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// Operator-selected bounds, not authority. The host freezes this exact value
// into an approved startup grant and every later invocation binding. Defaults
// retain the original Service profile; Tool/Pi preparation is unaffected.
public class ServiceProtocolLimits {
    public let isExplicit: Bool
    public let maxFrameBytes: Int64
    public let maxInputBytes: Int64
    public let maxPrepareBytes: Int64
    public let maxResultBytes: Int64
    public let maxDirectoryBytes: Int64
    public let maxTools: Int64
    public let callTimeoutMillis: Int64
    public init() {
        isExplicit = false; maxFrameBytes = 262144; maxInputBytes = 16384; maxPrepareBytes = 65536
        maxResultBytes = 262144; maxDirectoryBytes = 65536; maxTools = 64; callTimeoutMillis = 30000
    }
    init(frame: Int64, input: Int64, prepared: Int64, result: Int64, directory: Int64,
        tools: Int64, timeout: Int64) {
        isExplicit = true; maxFrameBytes = frame; maxInputBytes = input; maxPrepareBytes = prepared
        maxResultBytes = result; maxDirectoryBytes = directory; maxTools = tools; callTimeoutMillis = timeout
    }
    public prop prepareInputBytes: Int64 { get() { if (isExplicit) { maxInputBytes + 65536 } else { maxInputBytes } } }
    public prop canonicalBytes: Int64 { get() { if (isExplicit) { maxFrameBytes - 65536 } else { 196608 } } }
    public prop requestBytes: Int64 { get() { if (isExplicit) { (maxPrepareBytes - 65536) / 2 } else { 65536 } } }
    public func toValue(): AgentValue {
        objectValue([ValueField("max_frame_bytes", integerValue(maxFrameBytes)), ValueField("max_input_bytes", integerValue(maxInputBytes)),
            ValueField("max_prepare_bytes", integerValue(maxPrepareBytes)), ValueField("max_result_bytes", integerValue(maxResultBytes)),
            ValueField("max_directory_bytes", integerValue(maxDirectoryBytes)), ValueField("max_tools", integerValue(maxTools)),
            ValueField("call_timeout_ms", integerValue(callTimeoutMillis))])
    }
}

public func parseServiceProtocolLimits(value: AgentValue): Result<ServiceProtocolLimits> {
    if (!httpIntentExactFields(value, ["max_frame_bytes", "max_input_bytes", "max_prepare_bytes", "max_result_bytes",
        "max_directory_bytes", "max_tools", "call_timeout_ms"])) {
        return httpIntentError("service.protocol_limits_invalid", "service protocol limits require an exact operator-selected profile")
    }
    try {
        func number(name: String): Int64 {
            let item = value.field(name).getOrThrow()
            if (item.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("invalid protocol limit") }
            let result = Int64.parse(item.asNumberText())
            if (result.toString() != item.asNumberText()) { throw IllegalArgumentException("noncanonical protocol limit") }
            result
        }
        let frame = number("max_frame_bytes"); let input = number("max_input_bytes"); let prepared = number("max_prepare_bytes")
        let result = number("max_result_bytes"); let directory = number("max_directory_bytes")
        let tools = number("max_tools"); let timeout = number("call_timeout_ms")
        // 256 KiB reserves immutable configuration/binding/identity envelopes.
        // Input plus hex-encoded prepared bytes must coexist in the same frame.
        if (frame < 524288 || frame > 4194304 || input < 1 || input > 1048576 || prepared < 131072 || prepared > 2097152 ||
            input + prepared > frame - 262144 || result < 1 || result > frame - 65536 ||
            directory < 1 || directory > result || tools < 1 || tools > 8192 || timeout < 1 || timeout > 3600000) {
            return httpIntentError("service.protocol_limits_invalid", "service protocol profile exceeds bounded host or durable envelopes")
        }
        Result.Ok(ServiceProtocolLimits(frame, input, prepared, result, directory, tools, timeout))
    } catch (_: Exception) { httpIntentError("service.protocol_limits_invalid", "service protocol limits must be bounded canonical integers") }
}

public func serviceProtocolLimits(container: AgentValue): Result<ServiceProtocolLimits> {
    match (container.field("protocol_limits")) {
        case None => Result.Ok(ServiceProtocolLimits())
        case Some(value) => parseServiceProtocolLimits(value)
    }
}

public func sameServiceProtocolLimits(grant: AgentValue, binding: AgentValue): Bool {
    match ((grant.field("protocol_limits"), binding.field("protocol_limits"))) {
        case (None, None) => true
        case (Some(left), Some(right)) => parseServiceProtocolLimits(left).isOk() && parseServiceProtocolLimits(right).isOk() &&
            canonicalAgentValue(left) == canonicalAgentValue(right)
        case _ => false
    }
}
