package tool_runtime

import agent_domain.*

// Data-only opt-in on the actual published executor. Core supplies its real
// retained canonical attempt plan after settlement; neither an ordinal nor a
// caller flag is an execution grant. The Store independently proves Source,
// the complete current plan, canonical result and Receipt before/after save.
public interface PreparedPostCanonicalToolObserver {
    func afterPreparedResultPersisted(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): Result<Unit>
}
