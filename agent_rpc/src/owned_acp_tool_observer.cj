package agent_rpc

import agent_domain.*
import agent_runtime.*

// acpUpdateFromEvent intentionally returns None for Extension payloads. The
// canonical owned Tool lifecycle is that same Extension payload. Preserve
// this concrete omission, without routing a full result through a naked
// String emitter or pretending typed ToolOutput/ToolCompleted were ignored.
func ignoreOwnedAcpToolExtension(event: OwnedAgentEvent): Result<Unit> {
    let result = event.withEvent(65536, { actual =>
        match (actual.payload) {
            case AgentEventPayload.Extension(kind, _) =>
                if (kind == AgentEventKind.Tool) { Result.Ok(()) }
                else { ownedRpcOutputError("acp.owned_event_unexpected") }
            case _ => ownedRpcOutputError("acp.owned_event_unexpected")
        }
    })
    match (result) { case Result.Err(error) => Result.Err(error)
        case Result.Ok(_) => event.closeAfterEventRetirement() }
}
