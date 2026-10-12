package tool_runtime

import agent_domain.*
import agent_runtime.*

// Scope is part of the host-issued owner's identity. There is one registry;
// these predicates project it without constructing a second mutable catalog.
func toolCatalogSameThread(left: ?ThreadId, right: ?ThreadId): Bool {
    match ((left, right)) {
        case (Some(a), Some(b)) => a.value == b.value
        case (None, None) => true
        case _ => false
    }
}

func toolRegistrationThread(registration: ToolRegistration): ?ThreadId {
    match (registration.owner) {
        case Some(owner) => owner.threadId
        case None => None
    }
}

func toolRegistrationVisible(registration: ToolRegistration, threadId: ?ThreadId): Bool {
    let scope = toolRegistrationThread(registration)
    scope.isNone() || toolCatalogSameThread(scope, threadId)
}

func toolCatalogScopesOverlap(left: ?ThreadId, right: ?ThreadId): Bool {
    left.isNone() || right.isNone() || toolCatalogSameThread(left, right)
}

func toolSnapshotThreadAllowed(snapshot: ToolSetSnapshot, threadId: ?ThreadId): Bool {
    snapshot.threadId.isNone() || toolCatalogSameThread(snapshot.threadId, threadId)
}

func validateToolSnapshotThread(context: ToolInvocationContext): Result<Unit> {
    if (!context.permitsToolSnapshotThread159(ThreadId(context.sessionId.value))) {
        return Result.Err(AgentError(AgentErrorKind.Conflict,
            "tool.snapshot_thread_mismatch", "tool snapshot belongs to another Thread"))
    }
    Result.Ok(())
}
