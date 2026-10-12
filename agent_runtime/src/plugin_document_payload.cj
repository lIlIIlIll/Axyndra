package agent_runtime

import agent_domain.*

// The actual Store creates a private implementation for one supplied
// transaction. This interface is descriptive, cannot be decoded from JSON,
// and does not expose a filesystem path or a reusable repository handle.
public interface PluginDocumentPayloadReadProof <: PluginDocumentReadProof {
    prop key: String
    prop revision: Int64
    prop bytes: Int64
}

// Host-only adapter. Default ports reject the reference-bearing read path.
// The Product implementation reserves raw-byte memory before selecting the
// payload and retains any unacknowledged writer in its ContextRead owner.
public interface PluginDocumentPayloadMaterializer {
    func materialize(proof: PluginDocumentPayloadReadProof): Result<AgentValue>
}

// A private Store instance exists only inside the actual derived settlement
// transaction, after source/plan/handoff and the current Host guard. It is not
// a file capability. The trusted Product reader downcasts this interface and
// consumes its one-shot window; a worker cannot return a proof or raw path.
public interface PluginDocumentPayloadCommitProof {
    prop runId: RunId
    prop parentOperationId: OperationId
    prop operationId: OperationId
    func payload(): AgentValue
}

public interface PluginDocumentPayloadCommitter {
    func commit(proof: PluginDocumentPayloadCommitProof): Result<Unit>
}
