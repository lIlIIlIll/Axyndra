package agent_host_runtime

import agent_domain.*
import agent_store.*
import tool_runtime.*

// Measure the actual durable codec, not JSON/IPC length. Leave 64 KiB for
// canonical identity/receipt wrappers: all native identities are <=256 bytes.
// The final plan is separately checked with the complete Store serializer.
public func hostManagedServiceDurableValueFits(value: AgentValue): Bool {
    try { encodeStoredValue(value).size <= 8388608 - 65536 }
    catch (_: Exception) { false }
}
func hostManagedServiceDurableResult(prepared: PreparedToolInvocation, value: ToolResult): Result<ToolResult> {
    try {
        let receipt = if (value.receiptId == "") { "receipt-" + prepared.operationId.value } else { value.receiptId }
        let content = ThreadItemContent.ToolResult(CanonicalToolCallId(prepared.call.callId), prepared.operationId,
            receipt, value.output, value.isError)
        if (hostManagedServiceDurableValueFits(value.output) && encodeStoredThreadContent(content).size <= 8388608 - 65536) {
            return Result.Ok(value)
        }
    } catch (_: Exception) {}
    // A transport may already have written. Preserve a small Unknown receipt;
    // never convert oversized post-effect evidence into a replayable failure.
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.service_result_codec_limit",
        "service result exceeds the durable codec envelope; effects require reconciliation"))
}

func hostManagedServiceSummaryLimit(grant: AgentValue, oldLimit: Int64): Int64 {
    let limits = serviceProtocolLimits(grant).value().getOrThrow()
    if (limits.isExplicit) { limits.maxDirectoryBytes + 65536 } else { oldLimit }
}
