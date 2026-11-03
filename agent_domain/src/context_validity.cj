package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// This optional data ceiling only restricts use of a frozen contribution. It
// is neither read authority nor a revision, lease, Source or permission grant.
// Historical codecs preserve it without consulting the current clock.
public func contextValueValidUntilMillis(value: AgentValue): Int64 {
    let field = match (value.field("valid_until_millis")) { case Some(item) => item; case None => return 0 }
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("context.validity_invalid") }
    let result = Int64.parse(field.asNumberText())
    if (result < 1 || result.toString() != field.asNumberText()) { throw IllegalArgumentException("context.validity_invalid") }
    result
}

public func validateContextSnapshotUse(snapshot: InvocationContextProjection): Result<Unit> {
    let now = agentUtcMillis()
    for (contribution in snapshot.contributions()) {
        if (contribution.validUntilMillis > 0 && now >= contribution.validUntilMillis) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "context.contribution_expired",
                "frozen content expired before its actual consumer")) }
    }
    Result.Ok(())
}
