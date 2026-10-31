package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson_support.*

// Host composition port only. Plugin JSON cannot construct the preparation or
// its closure. Execution stays in the existing ContextRead Operation pipeline.
public class InitialContextPreparation {
    public let read: ToolPreparationRead
    public let validity: () -> Result<Unit>
    public let sequence: ?ContextReadSequence
    public init(read: ToolPreparationRead, validity!: () -> Result<Unit> = { => Result.Ok(()) },
        sequence!: ?ContextReadSequence = None) {
        this.read = read; this.validity = validity; this.sequence = sequence
    }
}
public interface InitialContextPreparationPort {
    func prepare(request: AgentRunRequest, context: ToolInvocationContext,
        active: ActiveRunSnapshot): Result<InitialContextPreparation>
}

// Diagnostic data, deliberately not a RunningModel/WaitingApproval encoding.
// A crash here cannot turn a host closure into a replayable model Attempt.
func initialContextRequestValue(request: AgentRunRequest, epoch: Int64): AgentValue {
    objectValue([
        ValueField("schema", textValue("axyndra.accepted-context-request/v1")),
        ValueField("run_id", textValue(request.runId.value)),
        ValueField("session_id", textValue(request.sessionId.value)),
        ValueField("epoch", integerValue(epoch)),
        ValueField("model", textValue(request.model)),
        ValueField("prompt", textValue(request.prompt)),
        ValueField("system", textValue(request.system)),
        ValueField("skill_stack", contextSnapshotValue(request.contextSnapshot)),
        ValueField("lane_id", textValue(request.executionLaneId.value)),
        ValueField("budget", coreBudgetSnapshot(request.budget)),
        ValueField("tool_context", toolContextDescriptorValue(request.toolContext)),
        ValueField("capabilities", listValue(request.capabilities.values.map { value => objectValue([
            ValueField("kind", textValue(capabilityDisplayName(value.kind))), ValueField("resource", textValue(value.resource))]) }))
    ])
}
