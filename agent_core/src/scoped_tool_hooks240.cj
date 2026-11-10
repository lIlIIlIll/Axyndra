package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Opt-in Context lifetime only. Core enforces a separate revocable view for
// each actual callback. This grants no Source or task-return authority. An
// asynchronous reader must explicitly retain its own paid Context consumer.
// Legacy CoreToolHookRuntime implementations keep their original open input.
public interface ScopedCoreToolHookRuntime240 <: CoreToolHookRuntime {}

func coreBeforeToolHookScope240(hooks: CoreToolHookRuntime, context: ToolInvocationContext,
    committed: CommittedToolCallRef, arguments: AgentValue): CoreToolHookDecision {
    if ((hooks as ScopedCoreToolHookRuntime240).isNone()) {
        return hooks.beforeTool(context, committed, arguments)
    }
    context.withScopedInvocation240<CoreToolHookDecision>({ view => hooks.beforeTool(view, committed, arguments) })
}
func coreAfterToolHookScope240(hooks: CoreToolHookRuntime, context: ToolInvocationContext,
    committed: CommittedToolCallRef, event: CoreToolHookPostEvent): Unit {
    if ((hooks as ScopedCoreToolHookRuntime240).isNone()) {
        hooks.afterTool(context, committed, event)
    } else { context.withScopedInvocation240<Unit>({ view => hooks.afterTool(view, committed, event) }) }
}
func coreAfterOwnedToolHookScope240(hooks: OwnedCoreToolHookRuntime, policy: CoreToolHookRuntime,
    context: ToolInvocationContext, committed: CommittedToolCallRef,
    eventFactory: (ThreadItem) -> CoreToolHookPostEvent, held: OwnedCanonicalThreadItemAliasCustody): Result<Unit> {
    if ((policy as ScopedCoreToolHookRuntime240).isNone()) {
        return hooks.afterOwnedTool(context, committed, eventFactory, held)
    }
    context.withScopedInvocation240<Result<Unit>>({ view => hooks.afterOwnedTool(view, committed, eventFactory, held) })
}
