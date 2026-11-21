package tool_runtime

import agent_domain.*

// Closed questions about the frozen plan. A match neither exports the plan nor
// grants execution; Source, capability and durable admission checks are separate.
public enum FrozenPluginPlanRule {
    LivePolicyParent | ReadonlyDelegationParent | DocumentParent | ReadViewParent |
    PrimitiveChildParent | PreparedCompletion | ReadViewChild | ReadViewChildOf(NormalizedOperationPlan) |
    ReadonlyTargetOf(NormalizedOperationPlan) | FilePlanPreviewOf(NormalizedOperationPlan) |
    HttpStreamChildOf(NormalizedOperationPlan) | ChannelChildOf(NormalizedOperationPlan) |
    HttpChildOf(NormalizedOperationPlan) | CapabilitiesWithin(CapabilitySet)

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
            case ReadonlyTargetOf(parent) => readonlyDelegationChildAllowed(parent, plan)
            case FilePlanPreviewOf(parent) => readonlyDelegationFilePlanProposalAllowed(parent, plan)
            case HttpStreamChildOf(parent) => httpStreamServiceChildAllowed(parent, plan)
            case ChannelChildOf(parent) => channelServiceChildAllowed(parent, plan)
            case HttpChildOf(parent) => httpServiceChildAllowed(parent, plan)
            case CapabilitiesWithin(ceiling) =>
                for (required in plan.requiredCapabilities where !ceiling.allows(required.kind, resource: required.resource)) {
                    return false
                }
                true
        }
    }
}
