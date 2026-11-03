package agent_domain

import logical_json_payload as payload

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_READONLY_DELEGATION_VERSION = "readonly-delegation/v1"
public let HOST_DERIVED_MAX_DEPTH: Int64 = 8
public let HOST_DERIVED_MAX_WIDTH: Int64 = 32
public let HOST_DERIVED_MAX_OPERATIONS: Int64 = 256

// Data-only narrowing rules. The host builds this envelope from the operator
// configuration and actual frozen catalog; its shape is NOT an authorization.
public func isFrozenReadonlyDelegationParentPlan(plan: NormalizedOperationPlan): Bool {
    if (!httpIntentExactFields(plan.canonicalArguments, ["input", "host_plan"]) ||
        plan.effectClass != OperationEffectClass.ReadOnly || plan.networkPolicy.mode != NetworkPolicyMode.Denied ||
        plan.retryDisposition != OperationRetryDisposition.Never ||
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => false; case _ => true }) { return false }
    let host = plan.canonicalArguments.field("host_plan").getOrThrow()
    let oldFields = host.field("tool_payload_limits").isNone()
    let baseFields = ArrayList<String>(["version", "plugin", "package_digest", "generation", "configuration_digest",
        "contribution", "tool_set_id", "tools", "max_calls", "max_depth"])
    match(host.field("file_plan_proposals")){
        case Some(value)=>
            if(value.unifiedKind!=ValueKind.Boolean){return false}
            baseFields.add("file_plan_proposals")
        case None=>()}
    match (host.field("input_attachment")) {
        case Some(value) => if (!toolInputAttachmentProfileValid(value)) { return false } else { baseFields.add("input_attachment") }
        case None => ()
    }
    if (!oldFields) {
        baseFields.add("tool_payload_limits")
        let payload = host.field("tool_payload_limits").getOrThrow()
        if (payload.unifiedKind != ValueKind.Null) {
            let profile = match (ordinaryToolPayloadLimitsFromValue(payload)) { case Some(value) => value; case None => return false }
            if (profile.contribution != httpIntentText(host, "contribution")) { return false }
        }
    }
    if (!httpIntentExactFields(host, baseFields.toArray()) ||
        httpIntentText(host, "version") != HOST_READONLY_DELEGATION_VERSION ||
        !httpServicePluginNamespace(httpIntentText(host, "plugin")) ||
        !httpServicePackageDigest(httpIntentText(host, "package_digest")) ||
        !httpIntentDigest(httpIntentText(host, "configuration_digest")) ||
        !channelIntentIdentifier(httpIntentText(host, "contribution")) ||
        httpIntentText(host, "tool_set_id") == "" || httpIntentText(host, "tool_set_id").size > 512 ||
        plan.toolName != "plugin." + httpIntentText(host, "plugin") + "." + httpIntentText(host, "contribution") ||
        plan.implementation.implementationFingerprint != httpIntentText(host, "plugin") + ":" + httpIntentText(host, "package_digest")) { return false }
    let generation = try { UInt64.parse(httpIntentText(host, "generation")) } catch (_: Exception) { 0u64 }
    let maxCalls = readonlyDelegationInteger(host, "max_calls")
    let maxDepth = readonlyDelegationInteger(host, "max_depth")
    let entries = host.field("tools").getOrThrow()
    if (generation == 0u64 || maxCalls < 1 || maxCalls > HOST_DERIVED_MAX_WIDTH || maxDepth < 2 ||
        maxDepth > HOST_DERIVED_MAX_DEPTH || entries.unifiedKind != ValueKind.List || entries.items.size > 32) { return false }
    let names = HashSet<String>(); let aliases = HashSet<String>()
    for (entry in entries.items) {
        if (!httpIntentExactFields(entry, ["alias", "name", "version", "fingerprint", "schema_digest", "package_digest", "generation", "services"]) ||
            !channelIntentIdentifier(httpIntentText(entry, "alias")) || aliases.contains(httpIntentText(entry, "alias")) ||
            !httpIntentText(entry, "name").startsWith("plugin.") || names.contains(httpIntentText(entry, "name")) ||
            httpIntentText(entry, "name") == plan.toolName || httpIntentText(entry, "version") == "" ||
            httpIntentText(entry, "version").size > 512 || httpIntentText(entry, "fingerprint") == "" ||
            httpIntentText(entry, "fingerprint").size > 512 || !httpIntentDigest(httpIntentText(entry, "schema_digest")) ||
            !httpServicePackageDigest(httpIntentText(entry, "package_digest")) ||
            (try { UInt64.parse(httpIntentText(entry, "generation")) } catch (_: Exception) { 0u64 }) == 0u64) { return false }
        let services = entry.field("services").getOrThrow()
        if (services.unifiedKind != ValueKind.List || services.items.size != 1 ||
            services.items[0].unifiedKind != ValueKind.Text || services.items[0].text != "process.readview") { return false }
        names.add(httpIntentText(entry, "name")); aliases.add(httpIntentText(entry, "alias"))
    }
    let ceiling = CapabilitySet(values: plan.requiredCapabilities)
    if (!ceiling.allows(CapabilityKind.ExtensionInvoke, resource: plan.toolName)) { return false }
    for (entry in entries.items where !ceiling.allows(CapabilityKind.ExtensionInvoke, resource: httpIntentText(entry, "name"))) { return false }
    for (cap in plan.requiredCapabilities where cap.kind == CapabilityKind.ExtensionInvoke &&
        cap.resource != "" && cap.resource != plan.toolName && !names.contains(cap.resource)) { return false }
    for (cap in plan.requiredCapabilities where cap.kind != CapabilityKind.WorkspaceRead && cap.kind != CapabilityKind.ExtensionInvoke) { return false }
    stringifyUnifiedJson(host).size <= 65536
}

public func isReadonlyDelegatedChildPlan(plan: NormalizedOperationPlan): Bool {
    isFrozenReadViewParentPlan(plan) && plan.effectClass == OperationEffectClass.ReadOnly &&
        plan.networkPolicy.mode == NetworkPolicyMode.Denied
}

public func readonlyDelegationChildAllowed(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    if(readonlyDelegationFilePlanProposalAllowed(parent,child)){return true}
    if (!isFrozenReadonlyDelegationParentPlan(parent) || !isReadonlyDelegatedChildPlan(child)) { return false }
    let host = child.canonicalArguments.field("host_plan").getOrThrow()
    let entries = parent.canonicalArguments.field("host_plan").getOrThrow().field("tools").getOrThrow()
    var found = false
    for (entry in entries.items where httpIntentText(entry, "name") == child.toolName) {
        found = httpIntentText(entry, "version") == child.implementation.toolVersion &&
            httpIntentText(entry, "fingerprint") == child.implementation.implementationFingerprint &&
            httpIntentText(entry, "schema_digest") == child.implementation.schemaDigest &&
            httpIntentText(entry, "package_digest") == httpIntentText(host, "package_digest") &&
            httpIntentText(entry, "generation") == httpIntentText(host, "generation")
    }
    if (!found) { return false }
    let ceiling = CapabilitySet(values: parent.requiredCapabilities)
    for (cap in child.requiredCapabilities where !ceiling.allows(cap.kind, resource: cap.resource)) { return false }
    true
}

// This is only a narrowing predicate. The host freezes this optional flag
// from the actual operator configuration; Pipeline/Store still prove the live
// Root, every Derived edge, current catalog, capabilities, handoff and Receipt.
public func readonlyDelegationFilePlanProposalsEnabled(parent: NormalizedOperationPlan): Bool {
    if(!isFrozenReadonlyDelegationParentPlan(parent)){return false}
    match(parent.canonicalArguments.field("host_plan").getOrThrow().field("file_plan_proposals")){
        case Some(value)=>value.unifiedKind==ValueKind.Boolean && value.asBool()
        case None=>false}
}

public func readonlyDelegationFilePlanProposalAllowed(parent: NormalizedOperationPlan,child: NormalizedOperationPlan): Bool {
    if(!readonlyDelegationFilePlanProposalsEnabled(parent) || child.toolName!="host.file.plan.propose" ||
        child.effectClass!=OperationEffectClass.ReadOnly || child.networkPolicy.mode!=NetworkPolicyMode.Denied ||
        child.retryDisposition!=OperationRetryDisposition.Never ||
        match(child.replayDisposition){case ReplayDisposition.NeverReplay=>false;case _=>true} ||
        child.implementation.toolVersion!="host-file-plan-v2" ||
        child.implementation.implementationFingerprint!="host-file-plan-v2" ||
        !httpIntentExactFields(child.canonicalArguments,["plugin","generation","package_digest","proposal"]) ||
        child.canonicalArguments.field("proposal").getOrThrow().unifiedKind!=ValueKind.Object){return false}
    let actual=parent.canonicalArguments.field("host_plan").getOrThrow()
    for(key in ["plugin","generation","package_digest"]
        where httpIntentText(actual,key)!=httpIntentText(child.canonicalArguments,key)){return false}
    let ceiling=CapabilitySet(values:parent.requiredCapabilities)
    if(!parent.requiredCapabilities.any({cap=>cap.kind==CapabilityKind.WorkspaceRead}) ||
        !parent.requiredCapabilities.any({cap=>cap.kind==CapabilityKind.ExtensionInvoke}) ||
        child.requiredCapabilities.isEmpty()){return false}
    for(cap in child.requiredCapabilities where cap.kind!=CapabilityKind.WorkspaceRead ||
        !ceiling.allows(cap.kind,resource:cap.resource)){return false}
    true
}

public func readonlyDelegationRequestKey(parentCallId: String, childCallId: String): String {
    "readonly-delegation:" + parentCallId + ":" + childCallId
}

public func readonlyDelegationInteger(value: AgentValue, field: String): Int64 {
    payload.readonlyDelegationInteger(value, field)
}
