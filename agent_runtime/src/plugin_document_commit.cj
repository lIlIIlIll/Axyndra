package agent_runtime

import agent_domain.*

// Host-held callbacks only. A serialized proposal cannot create a participant
// or a Store proof. The default Operation port refuses this optional path.
public interface PluginDocumentCommitProof {
    prop runId: RunId
    prop parentOperationId: OperationId
    prop operationId: OperationId
    func plan(): NormalizedOperationPlan
    func receipt(): VNextOperationReceipt
}

public interface PluginDocumentCommitParticipant {
    func consume(proof: PluginDocumentCommitProof): Result<Unit>
}
