package agent_runtime

import agent_domain.*

// Host-held data adapter. This is never serialized to a worker, and neither
// the DTO it returns nor the interface can authorize a continuation or CAS.
public interface PluginDocumentReadProof {
    prop threadId: ThreadId
    prop runId: RunId
    prop operationId: OperationId
    prop laneId: LaneId
    func plan(): NormalizedOperationPlan
}

public interface PluginDocumentReadObserver {
    func observe(proof: PluginDocumentReadProof): Result<AgentValue>
}
