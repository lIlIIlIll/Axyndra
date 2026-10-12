package agent_app

import agent_domain.*
import agent_runtime.*
import agent_embed.*
import process4cj.{writeFdUtf8Checked182, writeFdUtf8LineChecked122}
import std.env.*
import yjson.*
import yjson_support.*

// This is the concrete synchronous stdout consumer used by --output json.
// It holds the complete original event only inside its paid borrow; the fixed
// writer owns each transient chunk until print returns. Only a successful
// final newline and stdout flush permit retirement of this event's alias.
func writeOwnedApplicationJsonEvent(event: OwnedAgentEvent): Result<Unit> {
    let result = event.withEvent(1048576, { actual =>
        match (actual.payload) {
            case AgentEventPayload.Extension(kind, detail) =>
                if (kind != AgentEventKind.Tool) { return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "app.json_owned_event_unexpected", "owned JSON output requires the canonical tool lifecycle event")) }
                var value: ?AgentValue = None
                try {
                    value = Some(objectValue([
                        ValueField("type", textValue("event")),
                        ValueField("sequence", integerValue(actual.sequence)),
                        ValueField("run_id", textValue(actual.runId.value)),
                        ValueField("event", detail)
                    ]))
                    match (writeOwnedRedactedAgentValue(value.getOrThrow(),
                        { part => appWriteOwnedJsonBytes182(part, false) }, { => Result.Ok(()) })) {
                        case Result.Err(error) => return Result.Err(error)
                        case Result.Ok(_) => () }
                    match (appWriteOwnedJsonBytes182("", true)) {
                        case Result.Err(error) => return Result.Err(error)
                        case Result.Ok(_) => () }
                    Result.Ok(())
                } finally {
                    // Drop the wrapper's actual full-detail reference before
                    // the original borrow can end and ACK can be requested.
                    match (value) { case Some(held) => let _ = held.asObject().remove("event")
                        case None => () }
                    value = None
                }
            case _ => Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "app.json_owned_event_unexpected", "owned JSON output requires the canonical tool lifecycle event"))
        }
    })
    match (result) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(_) => event.closeAfterEventRetirement() }
}

// Return the real IO failure through the original paid fixed writer.
// This carries no event alias, Source, receipt or retirement authority.
private func appWriteOwnedJsonBytes182(part: String, finalLine: Bool): Result<Unit> {
    try {
        getStdOut().flush()
        if (finalLine) { writeFdUtf8LineChecked122(1, part) }
        else { writeFdUtf8Checked182(1, part) }
        Result.Ok(())
    } catch (error: Exception) {
        Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "app.json_owned_output_failed", error.message))
    }
}
