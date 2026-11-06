package agent_product

import agent_domain.*
import tool_runtime.*

// Only the three concrete file-plan executors call this private DATA helper.
// The original invocation and Source stay untouched. Its independently paid
// metadata consumer follows the real result to the original canonical ACK.
func productFilePlanResultMetadata204(prepared: PreparedToolInvocation,
    action: (NormalizedOperationPlan, ToolCall) -> Result<ToolResult>): Result<ToolResult> {
    let consumer = match (prepared.retainMetadataConsumer204()) {
        case Some(value) => value
        // Legacy Raw exports keep their original conservative retention.
        case None => return action(prepared.operationPlan, prepared.call) }
    let result = consumer.withOperationPlan204({ plan =>
        consumer.withCall204({ call => action(plan, call) }) })
    match (result) {
        // A typed error is not proof its external consumers returned.
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(value) => Result.Ok(ToolResult(value.callId, value.output,
            isError: value.isError, receiptId: value.receiptId,
            payloadLease: Some(ToolResultPayloadLease({ =>
                value.releasePayload()
                consumer.returnConsumerFrame204()
            }))))
    }
}
