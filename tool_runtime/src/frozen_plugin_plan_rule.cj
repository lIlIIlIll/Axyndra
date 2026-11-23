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

// Current operator/package facts can be compared without giving their caller
// the frozen input. These are separate checks so Host can preserve its errors.
public enum FrozenReadViewCheck {
    Identity(String, String, UInt64, String) | Grant(String, Bool) |
    PayloadLimits(AgentValue) | Deadline(?AgentValue)

    func matches(arguments: AgentValue): Bool {
        let host = match (arguments.field("host_plan")) { case Some(value) => value; case None => return false }
        match (this) {
            case Identity(namespace, tool, generation, digest) =>
                httpIntentText(host, "plugin") == namespace && httpIntentText(host, "contribution") == tool &&
                    httpIntentText(host, "generation") == generation.toString() && httpIntentText(host, "package_digest") == digest
            case Grant(digest, granted) =>
                match (host.field("read_granted")) {
                    case Some(value) => value.unifiedKind == ValueKind.Boolean && value.asBool() == granted &&
                        httpIntentText(host, "configuration_digest") == digest
                    case None => false
                }
            case PayloadLimits(expected) =>
                match (host.field("tool_payload_limits")) {
                    case Some(value) => canonicalAgentValuesEqual(expected, value)
                    case None => false
                }
            case Deadline(selected) =>
                let intents = match (host.field("intents")) { case Some(value) => value; case None => return false }
                if (intents.unifiedKind != ValueKind.List || intents.items.size != 1) { return false }
                let intent = intents.items[0]
                canonicalAgentValuesEqual(selected ?? nullValue(), intent.field("deadline_profile") ?? nullValue()) &&
                    validateReadViewIntent(intent).isOk()
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
    ReadonlyDelegatedChild | HttpStreamParent | ChannelParent | AllowsChild(FrozenPluginChildRelation, PreparedToolInvocation) |
    DerivableParent(Bool, Bool) | PermitsDerivedIntent(NormalizedOperationPlan, String, String, String) |
    FileApplicationContentsMatch(AgentValue, AgentValue) | ReadViewFact(FrozenReadViewCheck) | Effect(OperationEffectClass) |
    ReadonlyExecTarget(String, String, String, String) | AllowsExtension(String) |
    AllowsNativeReadViewCapabilities(PreparedToolInvocation, CapabilitySet) |
    PluginServiceCeiling(CapabilitySet, Bool) | TransportBinding(String) |
    ReadonlyCallWithinWidth(Int64) | RequiresCapability(CapabilityKind)

    // A broker may already own the parent plan (Task or durable Store).
    // Otherwise both Prepared participants pin their own DATA for this call.
    public func matches(plan: NormalizedOperationPlan): Bool {
        match (this) {
            case Effect(expected) => plan.effectClass == expected
            case ReadonlyCallWithinWidth(count) =>
                count <= readonlyDelegationInteger(plan.canonicalArguments.field("host_plan").getOrThrow(), "max_calls")
            case RequiresCapability(kind) => requiresCapability(plan.requiredCapabilities, kind)
            case AllowsExtension(name) =>
                CapabilitySet(values: plan.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke, resource: name)
            case TransportBinding(expected) =>
                match (plan.canonicalArguments.field("host_plan")) {
                    case Some(host) => match (host.field("binding")) {
                        case Some(binding) => canonicalAgentValueMatches(binding, expected)
                        case None => false
                    }
                    case None => false
                }
            case PluginServiceCeiling(current, needsRead) =>
                let name = plan.toolName
                name.startsWith("plugin.") && CapabilitySet(values: plan.requiredCapabilities).allows(
                    CapabilityKind.ExtensionInvoke, resource: name) && current.allows(CapabilityKind.ExtensionInvoke, resource: name) &&
                    (!needsRead || (requiresCapability(plan.requiredCapabilities, CapabilityKind.WorkspaceRead) &&
                        current.allows(CapabilityKind.WorkspaceRead)))
            case AllowsNativeReadViewCapabilities(child, current) =>
                child.nativeReadViewCapabilitiesWithin(CapabilitySet(values: plan.requiredCapabilities), current)
            case ReadonlyExecTarget(name, version, fingerprint, schema) =>
                plan.toolName == name && plan.implementation.toolVersion == version &&
                    plan.implementation.implementationFingerprint == fingerprint && plan.implementation.schemaDigest == schema &&
                    plan.effectClass == OperationEffectClass.ReadOnly && networkPolicyModeIsDenied(plan.networkPolicy.mode)
            case ReadViewFact(check) => check.matches(plan.canonicalArguments)
            case FileApplicationContentsMatch(operations, patch) =>
                let arguments = plan.canonicalArguments
                match ((arguments.field("operations"), arguments.field("patch_artifact"))) {
                    case (Some(actual), Some(metadata)) =>
                        canonicalAgentValuesEqual(actual, operations) && canonicalAgentValuesEqual(metadata, patch)
                    case _ => false
                }
            case DerivableParent(alreadyDerived, readViewTarget) =>
                !alreadyDerived || (isReadonlyDelegatedChildPlan(plan) && readViewTarget)
            case PermitsDerivedIntent(child, parentCallId, childCallId, requestKey) =>
                (exactServiceChildAllowed(plan, child) && requestKey == exactServiceRequestKey(parentCallId, child)) ||
                (readonlyDelegationChildAllowed(plan, child) && requestKey == readonlyDelegationRequestKey(parentCallId, childCallId))
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
