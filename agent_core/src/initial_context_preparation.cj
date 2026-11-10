package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
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

// Preparation DATA only. This carries no ModelLane, Catalog/tool snapshot,
// invocation authority, Source or execution handoff. Retaining this input
// cannot retain the Core's private tool-set view.
public class InitialContextPreparationInput159 {
    public let threadId: ThreadId
    public let runId: RunId
    public let epoch: Int64
    public let contextSnapshot: InvocationContextProjection
    public let cancellation: CancellationToken
    public init(threadId: ThreadId, runId: RunId, epoch: Int64,
        contextSnapshot: InvocationContextProjection, cancellation: CancellationToken) {
        this.threadId = threadId; this.runId = runId; this.epoch = epoch
        this.contextSnapshot = contextSnapshot; this.cancellation = cancellation
    }
}
// An optional narrower host composition port. Avoiding an unnecessary lane
// copy is not a retirement witness. Open preparation/continuation callbacks
// keep the original conservative Context payments. An opt-in scoped sequence
// returns only its own actual views; parent retirement still requires the
// complete private Core producer and original task/consumer witnesses. The
// legacy port still receives its independent paid snapshot.
public interface InitialContextPreparationInputPort159 <: InitialContextPreparationPort {
    func prepareInput159(prompt: String, input: InitialContextPreparationInput159): Result<InitialContextPreparation>
}

// Diagnostic data, deliberately not a RunningModel/WaitingApproval encoding.
// A crash here cannot turn a host closure into a replayable model Attempt.
func initialContextRequestValue(request: AgentRunRequest, epoch: Int64): AgentValue {
    contextBoundaryRequestRequire(request.planContextFacts.unifiedKind == ValueKind.Object,
        "plan context facts must be an object")
    let snapshot = objectValue([
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
    if (!request.planContextFacts.fields.isEmpty()) {
        snapshot.put("plan_context_facts", contextBoundaryRequestFreeze(request.planContextFacts))
    }
    snapshot
}
