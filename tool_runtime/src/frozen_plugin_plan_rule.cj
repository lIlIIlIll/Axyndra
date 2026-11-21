package tool_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Closed questions about the frozen plan. A match neither exports the plan nor
// grants execution; Source, capability and durable admission checks are separate.
public enum FrozenPluginChildRelation {
    ReadonlyTarget | FilePlanPreview | HttpStream | Channel | ReadView | Http

    func against(parent: NormalizedOperationPlan): FrozenPluginPlanRule {
        match (this) {
            case ReadonlyTarget => FrozenPluginPlanRule.ReadonlyTargetOf(parent)
            case FilePlanPreview => FrozenPluginPlanRule.FilePlanPreviewOf(parent)
            case HttpStream => FrozenPluginPlanRule.HttpStreamChildOf(parent)
            case Channel => FrozenPluginPlanRule.ChannelChildOf(parent)
            case ReadView => FrozenPluginPlanRule.ReadViewChildOf(parent)
            case Http => FrozenPluginPlanRule.HttpChildOf(parent)
        }
    }
}

public enum FrozenPluginPlanRule {
    LivePolicyParent | ReadonlyDelegationParent | DocumentParent | ReadViewParent |
    ReadonlyInputAttachment | ReadonlyFilePlanProposals | DocumentPayloadProtocol |
    PrimitiveChildParent | PreparedCompletion | ReadViewChild | ReadViewChildOf(NormalizedOperationPlan) |
    ReadonlyTargetOf(NormalizedOperationPlan) | FilePlanPreviewOf(NormalizedOperationPlan) |
    HttpStreamChildOf(NormalizedOperationPlan) | ChannelChildOf(NormalizedOperationPlan) |
    HttpChildOf(NormalizedOperationPlan) | CapabilitiesWithin(CapabilitySet) |
    ReadonlyDelegatedChild | HttpStreamParent | ChannelParent | AllowsChild(FrozenPluginChildRelation, PreparedToolInvocation)

    // A broker may already own the parent plan (Task or durable Store).
    // Otherwise both Prepared participants pin their own DATA for this call.
    public func matches(plan: NormalizedOperationPlan): Bool {
        match (this) {
            case AllowsChild(relation, child) => child.matchesFrozenPlan(relation.against(plan))
            case ReadonlyDelegatedChild => isReadonlyDelegatedChildPlan(plan)
            case HttpStreamParent => isFrozenHttpStreamParentPlan(plan)
            case ChannelParent => isFrozenChannelParentPlan(plan)
            case LivePolicyParent => isPluginLivePolicyParentPlan(plan)
            case ReadonlyDelegationParent => isFrozenReadonlyDelegationParentPlan(plan)
            case ReadonlyInputAttachment => isFrozenReadonlyDelegationParentPlan(plan) &&
                plan.canonicalArguments.field("host_plan").getOrThrow().field("input_attachment").isSome()
            case ReadonlyFilePlanProposals => readonlyDelegationFilePlanProposalsEnabled(plan)
            case DocumentPayloadProtocol =>
                // Select the validator, not its result. A version tag alone grants no effect.
                httpIntentText(plan.canonicalArguments.field("host_plan") ?? nullValue(), "version") == PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA ||
                    httpIntentText(plan.canonicalArguments.field("host_plan") ?? nullValue(), "version") == PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA
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
