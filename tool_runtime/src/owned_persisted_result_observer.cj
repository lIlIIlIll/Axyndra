package tool_runtime

import agent_domain.*
import agent_runtime.*

// Explicitly installed actual observers consume the complete canonical item
// from its same paid readback. A retaining observer must retain alias custody
// and retire its own references before checked alias close. Ordinary executor
// callbacks and unknown callbacks do not acquire this contract implicitly.
public interface OwnedPersistedToolResultObserver {
    func afterOwnedResultPersisted(context: ToolInvocationContext,
        held: OwnedCanonicalThreadItemAliasCustody): Result<Unit>
}

class OwnedPersistedCanonicalResultShape {
    var isError = false
    func read(item: ThreadItem): Result<Unit> {
        match (item.content) {
            case ThreadItemContent.ToolResult(_, _, _, _, error) => isError = error; Result.Ok(())
            case _ => Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.persisted_hook_canonical_result_missing", "actual complete canonical ToolResult is required")) }
    }
}
