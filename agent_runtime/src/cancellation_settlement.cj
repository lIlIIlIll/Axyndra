package agent_runtime

import agent_domain.*

public let CANCELLATION_SETTLEMENT_IMPLEMENTATION = "host-cancellation-settlement-v1"

// A description for closing an unprepared canonical call. It grants nothing;
// only the Store's actual Cancelling/epoch/Decision/Item transaction can record
// it, and that transaction marks the Operation permanently non-executable.
public func cancelledUnpreparedOperationPlan(runId: RunId, itemId: ItemId,
    call: ToolCall): NormalizedOperationPlan {
    NormalizedOperationPlan(call.name, call.arguments, [], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never, "cancelled-unprepared:" + runId.value + ":" + itemId.value,
        replayDisposition: Some(ReplayDisposition.NeverReplay),
        toolVersion: CANCELLATION_SETTLEMENT_IMPLEMENTATION,
        implementationFingerprint: CANCELLATION_SETTLEMENT_IMPLEMENTATION)
}

public func cancelledUnpreparedToolOutput(): AgentValue {
    objectValue([
        ValueField("error", textValue("tool.cancelled_during_preparation")),
        ValueField("message", textValue("preparation read was cancelled before this tool could execute"))
    ])
}
