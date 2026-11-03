package agent_host_runtime

import agent_domain.*
import agent_store.*

// Trusted host composition only. This fixed-purpose port binds one payload to
// its actual owner and immutable preparation witness inside HostArtifactStore's
// existing transaction. It is not part of a plugin/JS/SDK contribution, has no
// decoder, and never returns or stores the borrowed transaction. Implementors
// must not call Runtime gates while the transaction is held.
public interface HostArtifactPayloadPin {
    func requireCurrent(transaction: SqliteTransaction): Unit
    func retain(transaction: SqliteTransaction, payload: AgentValue): Unit
    func requireRetained(transaction: SqliteTransaction, payload: AgentValue): Unit
    func storageRequiredError(): AgentError
    func retentionError(reference: String): AgentError
    func readError(): AgentError
}
