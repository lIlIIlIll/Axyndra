package agent_domain

import yjson.*
import yjson_support.*

// Protocol-neutral JSON boundary used by host persistence and frontends.
// Keep the existing byte ceiling, error code, and JSON error evidence stable.
public func encodeAgentValue(value: AgentValue): String {
    stringifyUnifiedJson(value)
}

public func decodeAgentValue(
    source: String,
    maxBytes!: Int64 = 1048576
): Result<AgentValue> {
    try {
        Result.Ok(parseUnifiedJson(source, maxBytes: maxBytes))
    } catch (error: JsonException) {
        Result.Err(
            AgentError(
                AgentErrorKind.Protocol,
                "value.invalid_json",
                error.message,
                fields: [
                    ErrorField("json_error_kind", error.code)
                ]
            )
        )
    }
}

