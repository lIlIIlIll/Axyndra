package agent_app

import agent_domain.*
import agent_runtime.*

// Print has always ignored Tool lifecycle payloads. Its concrete no-op reads
// only the event classification; it neither retains output nor queues a frame.
// The full original item remains paid throughout the borrow. Only after that
// actual callback frame ends may this observer acknowledge its real alias.
func ignoreOwnedPrintToolLifecycle(event: OwnedAgentEvent): Result<Unit> {
    let classification = event.withEvent(65536, { actual =>
        if (actual.kind != AgentEventKind.Tool || extensionCode(actual.detail) == "model.text_delta") {
            return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "app.print_owned_event_unexpected", "print requires its original text event path")) }
        Result<Unit>.Ok(()) })
    match (classification) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(_) => event.closeAfterEventRetirement() }
}
