package agent_runtime

import agent_domain.*

public let DIRECT_PREPARATION_REJECTION = "host-direct-preparation-rejected-v1"
public func rejectedDirectPreparationPlan(source: DirectToolCallRef): NormalizedOperationPlan {
    rejectedDirectPreparationPlan(source.runId, source.canonicalItemId, source.call)
}
public func rejectedDirectPreparationPlan(runId: RunId, itemId: ItemId, call: ToolCall): NormalizedOperationPlan {
    NormalizedOperationPlan(call.name, call.arguments, [], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never, "unprepared-direct:" + runId.value + ":" + itemId.value,
        replayDisposition: Some(ReplayDisposition.NeverReplay), toolVersion: DIRECT_PREPARATION_REJECTION,
        implementationFingerprint: DIRECT_PREPARATION_REJECTION)
}
public func rejectedDirectPreparationOutput(): AgentValue {
    objectValue([ValueField("error", textValue("tool.preparation_not_executed")),
        ValueField("message", textValue("the original Direct tool did not execute because preparation did not complete"))])
}
