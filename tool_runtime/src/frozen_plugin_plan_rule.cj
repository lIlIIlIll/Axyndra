package tool_runtime

import agent_domain.*

// Closed questions about the frozen plan. A match neither exports the plan nor
// grants execution; Source, capability and durable admission checks are separate.
public enum FrozenPluginPlanRule {
    LivePolicyParent | ReadonlyDelegationParent | DocumentParent | ReadViewParent |
    PrimitiveChildParent | PreparedCompletion | ReadViewChild | ReadViewChildOf(NormalizedOperationPlan)

    func matches(plan: NormalizedOperationPlan): Bool {
        match (this) {
            case LivePolicyParent => isPluginLivePolicyParentPlan(plan)
            case ReadonlyDelegationParent => isFrozenReadonlyDelegationParentPlan(plan)
            case DocumentParent => isFrozenPluginDocumentParentPlan(plan)
            case ReadViewParent => isFrozenReadViewParentPlan(plan)
            case PrimitiveChildParent => isFrozenPluginChildParent111(plan)
            case PreparedCompletion => isFrozenPluginPreparedCompletion152(plan)
            case ReadViewChild => isReadViewServiceChildPlan(plan)
            case ReadViewChildOf(parent) => readViewServiceChildAllowed(parent, plan)
        }
    }
}
