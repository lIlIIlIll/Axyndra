package agent_product

import agent_domain.*
import tool_runtime.*

// The plugin preview still reads the whole frozen plan.
// The original invocation and Source stay untouched. Its independently paid
// metadata consumer follows the real result to the original canonical ACK.
func productFilePlanResultMetadata204(prepared: PreparedToolInvocation,
    action: (NormalizedOperationPlan, ToolResolverInput) -> Result<ToolResult>): Result<ToolResult> {
    let consumer = match (prepared.retainMetadataConsumer204()) {
        case Some(value) => value
        // The uncounted plan retains its original conservative export.
        case None =>
            let plan = prepared.operationPlan
            return prepared.withCallInput({ input => action(plan, input) })
    }
    let result = consumer.withOperationPlan204({ plan =>
        consumer.withCallInput({ input => action(plan, input) }) })
    productFilePlanResultAfterConsumer204(result, consumer)
}

func withFilePlanCanonicalInput(prepared: PreparedToolInvocation,
    action: (ToolResolverInput, ?PreparedMetadataConsumer204) -> Result<ToolResult>): Result<ToolResult> {
    match (prepared.retainMetadataConsumer204()) {
        case Some(consumer) =>
            let result = consumer.withCanonicalCallInput({ call => action(call, Some(consumer)) })
            productFilePlanResultAfterConsumer204(result, consumer)
        case None => prepared.withCanonicalCallInput({ call => action(call, None) })
    }
}

func productFilePlanResultAfterConsumer204(result: Result<ToolResult>,
    consumer: PreparedMetadataConsumer204): Result<ToolResult> {
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
