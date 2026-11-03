package persistence_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// The transport caller prepays its input text, original grammar/DOM and
// independently retained output before this synchronous DATA-only decoder.
// Preserve the exact existing full-eight-field attachment/diagnostic codec.
public func decodeCompleteProcessBrokerError180(value:AgentValue):Result<AgentError>{
    if(!failureExactFields113(value,["kind","code","message","retryable","fallback_allowed",
        "fields","attempt_failure","observation"])){return codecError("complete broker error fields changed")}
    strictFailureError113(value)
}
