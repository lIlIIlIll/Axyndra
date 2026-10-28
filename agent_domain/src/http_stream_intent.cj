package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_HTTP_STREAM_TOOL = "host.network.http.stream"
public let HOST_HTTP_STREAM_INTENT_VERSION = "http-stream-intents/v1"
public let HOST_HTTP_STREAM_PAYLOAD_INTENT_VERSION = "http-stream-intents/v2"
public let HOST_HTTP_STREAM_FINGERPRINT = "host-http-stream-v1"

// Published identity metadata only. Live resource checks and the completed
// canonical startup proof remain mandatory at each actual handoff.
public func validateHttpStreamBinding(binding: AgentValue): Result<Unit> {
    if (!serviceEffectBindingFields(binding, ["plugin", "package_digest", "configuration_digest",
        "instance_identity", "endpoint_identity", "resource_id", "grant_digest", "startup_operation_id",
        "target_thread_id", "permission_domain", "directory_revision", "directory_digest",
        "implementation_version", "implementation_fingerprint", "schema_digest", "workspace_root", "network"]) ||
        !httpServicePluginNamespace(httpIntentText(binding, "plugin")) ||
        !httpServicePackageDigest(httpIntentText(binding, "package_digest"))) {
        return httpIntentError("http.stream_binding_invalid", "HTTP stream binding fields or package identity are invalid")
    }
    for (key in ["configuration_digest", "endpoint_identity", "grant_digest", "permission_domain", "directory_digest", "schema_digest"]) {
        if (!httpIntentDigest(httpIntentText(binding, key))) {
            return httpIntentError("http.stream_binding_invalid", "HTTP stream binding contains an invalid digest")
        }
    }
    for (key in ["instance_identity", "resource_id", "startup_operation_id", "target_thread_id", "implementation_version"]) {
        if (!channelIntentIdentifier(httpIntentText(binding, key))) {
            return httpIntentError("http.stream_binding_invalid", "HTTP stream binding contains an invalid identity")
        }
    }
    let fingerprint = httpIntentText(binding, "implementation_fingerprint")
    if (!fingerprint.startsWith("owned-v1:") || !httpIntentDigest(fingerprint[9..])) {
        return httpIntentError("http.stream_binding_invalid", "HTTP stream requires an owned contribution identity")
    }
    let revision = binding.field("directory_revision").getOrThrow()
    let number = try { Int64.parse(revision.asNumberText()) } catch (_: Exception) { 0 }
    let workspace = httpIntentText(binding, "workspace_root")
    if (revision.unifiedKind != ValueKind.Number || number < 1 || number.toString() != revision.asNumberText() ||
        workspace == "" || workspace.size > 4096 || workspace.contains("\u{0}")) {
        return httpIntentError("http.stream_binding_invalid", "HTTP stream revision or workspace identity is invalid")
    }
    match (parseNetworkPolicy(binding.field("network").getOrThrow())) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(policy) => if (policy.mode != NetworkPolicyMode.Mediated || policy.egress.isEmpty() || !policy.publish.isEmpty()) {
            return httpIntentError("http.stream_binding_invalid", "HTTP stream binding requires finite mediated origins")
        }
    }
    Result.Ok(())
}

public func httpStreamServiceRequiredCapabilities(binding: AgentValue): Result<Array<Capability>> {
    match (validateHttpStreamBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let policy = parseNetworkPolicy(binding.field("network").getOrThrow()).value().getOrThrow()
    let values = ArrayList<Capability>([Capability(CapabilityKind.ExtensionInvoke)])
    for (rule in policy.egress) { values.add(Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(rule))) }
    Result.Ok(values.toArray())
}

public func httpStreamIntentPolicy(intent: AgentValue, binding!: ?AgentValue = None): Result<NetworkPolicy> {
    if (!httpIntentExactFields(intent, ["id", "request", "network"]) || !httpIntentIdentifier(httpIntentText(intent, "id"))) {
        return httpIntentError("http.stream_intent_invalid", "HTTP stream intent requires one exact request and network rule")
    }
    let policy = match (parseNetworkPolicy(intent.field("network").getOrThrow())) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
    }
    let profile: ?ServicePayloadLimits = match (binding) { case Some(value) => match (servicePayloadLimits(value)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(limits) => limits }; case None => None }
    let maximum = match (profile) { case Some(value) => value.maxWriteBytes; case None => HOST_HTTP_STREAM_REQUEST_MAX_BYTES }
    let response = match (profile) { case Some(value) => value.maxResultBytes; case None => HOST_HTTP_STREAM_RESPONSE_MAX_BYTES }
    match (httpStreamRequestPolicy(intent.field("request").getOrThrow(), policy, maximumBytes: maximum,
        responseBytes: response, allowPayload: profile.isSome())) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
    }
    Result.Ok(policy)
}

public func httpStreamServiceChildArguments(parent: AgentValue, id: String): Result<AgentValue> {
    if (!httpIntentExactFields(parent, ["input", "configuration", "host_plan"])) {
        return httpIntentError("http.stream_parent_invalid", "HTTP stream requires a bounded frozen parent")
    }
    let host = parent.field("host_plan").getOrThrow()
    if (!httpIntentExactFields(host, ["version", "binding", "intents"]) ||
        (httpIntentText(host, "version") != HOST_HTTP_STREAM_INTENT_VERSION &&
         httpIntentText(host, "version") != HOST_HTTP_STREAM_PAYLOAD_INTENT_VERSION)) {
        return httpIntentError("http.stream_parent_invalid", "HTTP stream parent version or fields are invalid")
    }
    let binding = host.field("binding").getOrThrow()
    match (validateHttpStreamBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let payload = servicePayloadLimits(binding).value().getOrThrow()
    let usesPayload = httpIntentText(host, "version") == HOST_HTTP_STREAM_PAYLOAD_INTENT_VERSION
    if (usesPayload != payload.isSome()) { return httpIntentError("http.stream_parent_invalid", "HTTP payload version and approved profile differ") }
    let maximum = match (payload) { case Some(value) => value.maxWriteBytes; case None => HOST_HTTP_STREAM_REQUEST_MAX_BYTES }
    let canonicalLimit = httpStreamPayloadCanonicalBytes(binding)
    if (channelParentJsonByteSize(parent) > canonicalLimit) { return httpIntentError("http.stream_parent_invalid", "frozen parent exceeds the approved profile") }
    let ceiling = parseNetworkPolicy(binding.field("network").getOrThrow()).value().getOrThrow()
    let intents = host.field("intents").getOrThrow()
    if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty() || intents.items.size > 4) {
        return httpIntentError("http.stream_intents_invalid", "HTTP stream parent must declare one to four exact requests")
    }
    let seen = HashSet<String>()
    var selected: ?AgentValue = None
    var bodyBytes: Int64 = 0
    for (intent in intents.items) {
        let policy = match (httpStreamIntentPolicy(intent, binding: Some(binding))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let key = httpIntentText(intent, "id")
        let required = networkEgressResource(policy.egress[0])
        var granted = false
        for (rule in ceiling.egress where networkEgressResource(rule) == required) { granted = true }
        let request = intent.field("request").getOrThrow()
        let count = httpStreamRequestBodySize(request, maximum, usesPayload).value().getOrThrow()
        // Under v2 every nonempty request is host-staged, never inline plugin bytes.
        if (usesPayload && count > 0 && request.field("body_payload").isNone()) {
            return httpIntentError("http.stream_payload_not_staged", "HTTP payload requires the host preparation witness")
        }
        bodyBytes += count
        if (seen.contains(key) || !granted || bodyBytes > maximum) {
            return httpIntentError("http.stream_intents_invalid", "HTTP stream intents repeat, exceed limits or change their granted origin")
        }
        seen.add(key)
        if (id == key) { selected = Some(intent) }
    }
    let intent = match (selected) {
        case Some(value) => value
        case None => return httpIntentError("http.stream_intent_missing", "HTTP stream intent is absent from the frozen parent")
    }
    Result.Ok(parseUnifiedJson(stringifyUnifiedJson(objectValue([
        ValueField("binding", binding), ValueField("intent", intent)])), maxBytes: canonicalLimit))
}

public func isFrozenHttpStreamParentPlan(parent: NormalizedOperationPlan): Bool {
    if (!httpIntentExactFields(parent.canonicalArguments, ["input", "configuration", "host_plan"]) ||
        !serviceParentEffectAllowed(parent)) { return false }
    let host = parent.canonicalArguments.field("host_plan").getOrThrow()
    let intents = match (host.field("intents")) { case Some(value) => value; case None => return false }
    if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty()) { return false }
    let args = match (httpStreamServiceChildArguments(parent.canonicalArguments, httpIntentText(intents.items[0], "id"))) {
        case Result.Err(_) => return false; case Result.Ok(value) => value
    }
    let binding = args.field("binding").getOrThrow()
    if (!parent.toolName.startsWith("plugin." + httpIntentText(binding, "plugin") + ".") ||
        parent.implementation.toolVersion != httpIntentText(binding, "implementation_version") ||
        parent.implementation.implementationFingerprint != httpIntentText(binding, "implementation_fingerprint") ||
        parent.implementation.schemaDigest != httpIntentText(binding, "schema_digest")) { return false }
    let required = httpStreamServiceRequiredCapabilities(binding).value().getOrThrow()
    let ceiling = CapabilitySet(values: parent.requiredCapabilities)
    for (capability in required where !ceiling.allows(capability.kind, resource: capability.resource)) { return false }
    networkPoliciesEqual(parent.networkPolicy, parseNetworkPolicy(binding.field("network").getOrThrow()).value().getOrThrow())
}

public func isHttpStreamServiceChildPlan(child: NormalizedOperationPlan): Bool {
    if (child.toolName != HOST_HTTP_STREAM_TOOL || child.implementation.implementationFingerprint != HOST_HTTP_STREAM_FINGERPRINT ||
        child.implementation.toolVersion != HOST_HTTP_STREAM_FINGERPRINT ||
        !httpIntentExactFields(child.canonicalArguments, ["binding", "intent"]) || child.retryDisposition != OperationRetryDisposition.Never ||
        match (child.replayDisposition) { case ReplayDisposition.NeverReplay => false; case _ => true }) { return false }
    let binding = child.canonicalArguments.field("binding").getOrThrow()
    if (validateHttpStreamBinding(binding).isError()) { return false }
    let intent = child.canonicalArguments.field("intent").getOrThrow()
    let policy = match (httpStreamIntentPolicy(intent, binding: Some(binding))) { case Result.Err(_) => return false; case Result.Ok(value) => value }
    let effect = if (httpIntentText(intent.field("request").getOrThrow(), "method") == "GET") {
        OperationEffectClass.ReadOnly
    } else { OperationEffectClass.ExternalMutation }
    child.effectClass == effect && networkPoliciesEqual(child.networkPolicy, policy) &&
        child.requiredCapabilities.size == 1 && child.requiredCapabilities[0].kind == CapabilityKind.NetworkAccess &&
        child.requiredCapabilities[0].resource == networkEgressResource(policy.egress[0])
}

public func httpStreamServiceChildAllowed(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    if (!isFrozenHttpStreamParentPlan(parent) || !isHttpStreamServiceChildPlan(child)) { return false }
    match (httpStreamServiceChildArguments(parent.canonicalArguments,
        httpIntentText(child.canonicalArguments.field("intent").getOrThrow(), "id"))) {
        case Result.Err(_) => false
        case Result.Ok(expected) => canonicalAgentValue(expected) == canonicalAgentValue(child.canonicalArguments)
    }
}
