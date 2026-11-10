package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Only Product's private composition selects scoped Context inputs. The
// public ProductCodexHookRuntime keeps its legacy interface and direct-call
// behavior. Every execution, generation, cancellation and DATA owner remains
// on that same actual runtime; this adapter creates no independent authority.
class ProductScopedCoreToolHooks240 <: ScopedCoreToolHookRuntime240 {
    private let actual: ProductCodexHookRuntime
    init(actual: ProductCodexHookRuntime) { this.actual = actual }
    public func beforeTool(context: ToolInvocationContext, committed: CommittedToolCallRef,
        arguments: AgentValue): CoreToolHookDecision {
        actual.beforeTool(context, committed, arguments)
    }
    public func afterTool(context: ToolInvocationContext, committed: CommittedToolCallRef,
        event: CoreToolHookPostEvent): Unit {
        actual.afterTool(context, committed, event)
    }
}
