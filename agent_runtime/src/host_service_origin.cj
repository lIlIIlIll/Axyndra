package agent_runtime

import agent_domain.*

class HostDirectOriginSeal {}

// Capability created only by the live Thread owner after its maintenance
// initiator commits. It cannot be parsed, publicly constructed, or recovered.
public class HostServiceRunAdmission {
    public let run: ActiveRunSnapshot
    public let origin: HostServiceOrigin
    let seal: HostDirectOriginSeal
    init(run: ActiveRunSnapshot, origin: HostServiceOrigin, seal: HostDirectOriginSeal) {
        this.run = run; this.origin = origin; this.seal = seal
    }
}

// Deserializing history can recover descriptive origin, never the live seal.
func hostServiceOriginForRun(snapshot: AgentThreadSnapshot, turnId: SemanticTurnId, runId: RunId): ?HostServiceOrigin {
    for (turn in snapshot.turns where turn.id.value == turnId.value) {
        for (item in snapshot.items where item.id.value == turn.userItemId.value) {
            if (isHostServiceInitiator(item)) {
                if (item.provenance.runId.getOrThrow().value != runId.value) {
                    throw IllegalArgumentException("recovered host-service initiator belongs to another Run")
                }
                match (item.provenance.directOrigin) {
                    case Some(DirectCallOrigin.HostService(value)) => return Some(value)
                    case _ => ()
                }
            }
        }
    }
    None
}
