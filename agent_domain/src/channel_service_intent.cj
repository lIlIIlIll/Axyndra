package agent_domain

import logical_json_payload as payload

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_CHANNEL_WRITE_TOOL = "host.process.channel.write"
public let HOST_CHANNEL_INTENT_VERSION = "process-channel-intent-v1"
public let HOST_CHANNEL_WRITE_FINGERPRINT = "host-channel-write-v1"

// This is a bounded data contract, never a service lease or admission token.
// The Product executor must also select its exact host-held live lease and
// endpoint; Store independently proves the canonical parent and handoff.
public func validateChannelServiceBinding(binding: AgentValue): Result<Unit> {
    if (!serviceEffectBindingFields(binding, ["plugin", "package_digest", "configuration_digest",
        "instance_identity", "endpoint_identity", "lease_id", "launch_digest", "startup_operation_id",
        "target_thread_id", "permission_domain", "directory_revision", "directory_digest",
        "implementation_version", "implementation_fingerprint", "schema_digest", "workspace_root",
        "workspace_mode", "network"]) ||
        !httpServicePluginNamespace(httpIntentText(binding, "plugin")) ||
        !httpServicePackageDigest(httpIntentText(binding, "package_digest"))) {
        return channelIntentError("channel.binding_invalid", "channel binding has an unknown field or invalid package identity")
    }
    for (key in ["configuration_digest", "endpoint_identity", "launch_digest", "permission_domain",
        "directory_digest", "schema_digest"]) {
        if (!httpIntentDigest(httpIntentText(binding, key))) {
            return channelIntentError("channel.binding_invalid", "channel binding contains an invalid digest")
        }
    }
    for (key in ["instance_identity", "lease_id", "startup_operation_id", "target_thread_id", "implementation_version"]) {
        if (!channelIntentIdentifier(httpIntentText(binding, key))) {
            return channelIntentError("channel.binding_invalid", "channel binding contains an invalid host identity")
        }
    }
    let fingerprint = httpIntentText(binding, "implementation_fingerprint")
    if (!fingerprint.startsWith("owned-v1:") || !httpIntentDigest(fingerprint[9..])) {
        return channelIntentError("channel.binding_invalid", "channel preparation requires an owned catalog implementation")
    }
    let revision = binding.field("directory_revision").getOrThrow()
    let parsed = try { Int64.parse(revision.asNumberText()) } catch (_: Exception) { 0 }
    if (revision.unifiedKind != ValueKind.Number || parsed < 1 || parsed.toString() != revision.asNumberText()) {
        return channelIntentError("channel.binding_invalid", "channel directory revision must be a positive integer")
    }
    let workspace = httpIntentText(binding, "workspace_root")
    if (workspace.size < 1 || workspace.size > 4096 || workspace.contains("\u{0}")) {
        return channelIntentError("channel.binding_invalid", "channel workspace binding is invalid")
    }
    if (!["isolated_readonly", "workspace_readonly", "workspace_readwrite"].contains(httpIntentText(binding, "workspace_mode"))) {
        return channelIntentError("channel.binding_invalid", "channel workspace mode is not supported")
    }
    match (parseNetworkPolicy(binding.field("network").getOrThrow())) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(policy) => if (!policy.publish.isEmpty()) {
            return channelIntentError("channel.binding_invalid", "channel service cannot authorize listener publication")
        }
    }
    Result.Ok(())
}

public func channelServiceRequiredCapabilities(binding: AgentValue): Result<Array<Capability>> {
    match (validateChannelServiceBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let values = ArrayList<Capability>([Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)])
    let workspace = httpIntentText(binding, "workspace_root")
    let mode = httpIntentText(binding, "workspace_mode")
    if (mode == "workspace_readonly") { values.add(Capability(CapabilityKind.WorkspaceRead, resource: workspace)) }
    if (mode == "workspace_readwrite") {
        // A writable backend can also observe its mounted workspace. Freeze
        // both effects into the parent and child instead of inferring Read.
        values.add(Capability(CapabilityKind.WorkspaceRead, resource: workspace))
        values.add(Capability(CapabilityKind.WorkspaceWrite, resource: workspace))
    }
    let policy = match (parseNetworkPolicy(binding.field("network").getOrThrow())) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(value) => value
    }
    // Host networking is a distinct explicit capability resource, never an empty rule list.
    for (resource in networkPolicyCapabilityResources(policy)) {
        values.add(Capability(CapabilityKind.NetworkAccess, resource: resource))
    }
    Result.Ok(values.toArray())
}

public func channelServiceWriteBytes(intent: AgentValue, maximumBytes!: Int64 = 65536): Result<Array<Byte>> {
    if (maximumBytes < 1 || maximumBytes > 4194304) { return channelIntentError("channel.intent_bounds", "invalid host-selected write bound") }
    if (!httpIntentExactFields(intent, ["id", "bytes_hex"]) || !httpIntentIdentifier(httpIntentText(intent, "id"))) {
        return channelIntentError("channel.intent_invalid", "channel write requires exactly an intent ID and immutable bytes")
    }
    let encoded = httpIntentText(intent, "bytes_hex")
    if (encoded.size < 2 || encoded.size > maximumBytes * 2 || encoded.size % 2 != 0) {
        return channelIntentError("channel.intent_bounds", "channel write exceeds its host-selected byte bound")
    }
    let bytes = encoded.toArray()
    let output = Array<Byte>(encoded.size / 2, repeat: 0)
    for (index in 0..output.size) {
        let high = channelIntentHex(bytes[index * 2])
        let low = channelIntentHex(bytes[index * 2 + 1])
        if (high < 0 || low < 0) {
            return channelIntentError("channel.intent_encoding", "channel bytes must use canonical lowercase hexadecimal")
        }
        output[index] = UInt8(high * 16 + low)
    }
    Result.Ok(output)
}

public func channelServiceChildArguments(parent: AgentValue, id: String): Result<AgentValue> {
    if (!httpIntentExactFields(parent, ["input", "configuration", "host_plan"])) {
        return channelIntentError("channel.parent_invalid", "channel parent is not a bounded frozen host preparation")
    }
    let host = parent.field("host_plan").getOrThrow()
    // Background intent is host-frozen before approval. Its presence grants no
    // execution authority; the Task owner must obtain a sealed launch admission.
    let job = host.field("managed_job")
    if (job.isSome()) {
        try { let _ = managedJobDeclarationFromValue(job.getOrThrow()) }
        catch (_: Exception) { return channelIntentError("channel.managed_job_invalid", "managed job declaration is invalid") }
    }
    if (!httpIntentExactFields(host, if (job.isSome()) { ["version", "binding", "intents", "managed_job"] }
        else { ["version", "binding", "intents"] }) ||
        !([HOST_CHANNEL_INTENT_VERSION, HOST_CHANNEL_PAYLOAD_INTENT_VERSION].contains(httpIntentText(host, "version")))) {
        return channelIntentError("channel.parent_invalid", "channel host preparation version or fields are invalid")
    }
    let binding = host.field("binding").getOrThrow()
    match (validateChannelServiceBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let limits = serviceProtocolLimits(binding).value().getOrThrow()
    let payloadLimits = servicePayloadLimits(binding).value().getOrThrow()
    let artifactMode = httpIntentText(host, "version") == HOST_CHANNEL_PAYLOAD_INTENT_VERSION
    if (artifactMode && payloadLimits.isNone()) { return channelIntentError("channel.payload_not_granted", "artifact intent version requires a payload profile") }
    let canonicalLimit = if (artifactMode) { payloadLimits.getOrThrow().maxInputBytes + 262144 } else { limits.canonicalBytes }
    if (channelParentJsonByteSize(parent) > canonicalLimit) { return channelIntentError("channel.parent_invalid", "frozen parent exceeds the approved profile") }
    let intents = host.field("intents").getOrThrow()
    if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty() || intents.items.size > 16) {
        return channelIntentError("channel.intent_bounds", "channel parent must declare from 1 to 16 writes")
    }
    let seen = ArrayList<String>()
    var total: Int64 = 0
    var selected: ?AgentValue = None
    for (intent in intents.items) {
        if (artifactMode != intent.field("payload").isSome()) { return channelIntentError("channel.intent_version_mismatch", "inline and artifact intent versions cannot be mixed") }
        let bytes = match (channelServiceIntentBytes(intent, binding)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        total += bytes
        let key = httpIntentText(intent, "id")
        if (total > (if (artifactMode) { payloadLimits.getOrThrow().maxWriteBytes } else { limits.requestBytes }) || seen.contains(key)) {
            return channelIntentError("channel.intent_bounds", "channel writes exceed the approved profile or repeat an intent ID")
        }
        seen.add(key)
        if (key == id) { selected = Some(intent) }
    }
    let intent = match (selected) {
        case None => return channelIntentError("channel.intent_missing", "channel intent is absent from the frozen parent")
        case Some(value) => value
    }
    // Defensive clone: later plugin or caller mutation cannot alter the
    // returned exact request after a digest or approval has been computed.
    Result.Ok(parseUnifiedJson(stringifyUnifiedJson(objectValue([
        ValueField("binding", binding), ValueField("intent", intent)])), maxBytes: canonicalLimit))
}

public func isChannelServiceChildPlan(child: NormalizedOperationPlan): Bool {
    if (child.toolName != HOST_CHANNEL_WRITE_TOOL ||
        child.implementation.implementationFingerprint != HOST_CHANNEL_WRITE_FINGERPRINT ||
        !httpIntentExactFields(child.canonicalArguments, ["binding", "intent"]) ||
        !channelIntentNeverReplay(child)) { return false }
    let binding = child.canonicalArguments.field("binding").getOrThrow()
    let required = match (channelServiceRequiredCapabilities(binding)) {
        case Result.Err(_) => return false
        case Result.Ok(value) => value
    }
    if (channelServiceIntentBytes(child.canonicalArguments.field("intent").getOrThrow(), binding).isError() ||
        required.size != child.requiredCapabilities.size) { return false }
    for (index in 0..required.size) {
        if (required[index].kind != child.requiredCapabilities[index].kind ||
            required[index].resource != child.requiredCapabilities[index].resource) { return false }
    }
    let policy = match (parseNetworkPolicy(binding.field("network").getOrThrow())) {
        case Result.Err(_) => return false
        case Result.Ok(value) => value
    }
    networkPoliciesEqual(child.networkPolicy, policy)
}

public func isFrozenChannelParentPlan(parent: NormalizedOperationPlan): Bool {
    if (!httpIntentExactFields(parent.canonicalArguments, ["input", "configuration", "host_plan"]) ||
        !serviceParentEffectAllowed(parent)) { return false }
    let host = parent.canonicalArguments.field("host_plan").getOrThrow()
    let intents = match (host.field("intents")) { case None => return false; case Some(value) => value }
    if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty()) { return false }
    let args = match (channelServiceChildArguments(parent.canonicalArguments, httpIntentText(intents.items[0], "id"))) {
        case Result.Err(_) => return false
        case Result.Ok(value) => value
    }
    let binding = args.field("binding").getOrThrow()
    if (!parent.toolName.startsWith("plugin." + httpIntentText(binding, "plugin") + ".") ||
        parent.implementation.toolVersion != httpIntentText(binding, "implementation_version") ||
        parent.implementation.implementationFingerprint != httpIntentText(binding, "implementation_fingerprint") ||
        parent.implementation.schemaDigest != httpIntentText(binding, "schema_digest")) { return false }
    let required = channelServiceRequiredCapabilities(binding).value().getOrThrow()
    let ceiling = CapabilitySet(values: parent.requiredCapabilities)
    for (capability in required where !ceiling.allows(capability.kind, resource: capability.resource)) { return false }
    let policy = parseNetworkPolicy(binding.field("network").getOrThrow()).value().getOrThrow()
    networkPoliciesEqual(parent.networkPolicy, policy)
}

public func channelServiceChildAllowed(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    if (!isFrozenChannelParentPlan(parent) || !isChannelServiceChildPlan(child)) { return false }
    let id = httpIntentText(child.canonicalArguments.field("intent").getOrThrow(), "id")
    match (channelServiceChildArguments(parent.canonicalArguments, id)) {
        case Result.Err(_) => false
        case Result.Ok(expected) => canonicalAgentValue(expected) == canonicalAgentValue(child.canonicalArguments)
    }
}

// A single narrowing rule is shared by policy preparation and Store. Neither
// branch is an authorization proof without its actual canonical parent facts.
public func isExactServiceChildPlan(plan: NormalizedOperationPlan): Bool {
    isHttpServiceChildPlan(plan) || isChannelServiceChildPlan(plan) || isHttpStreamServiceChildPlan(plan) || isReadViewServiceChildPlan(plan) || isPluginDocumentChildPlan(plan) || isPluginChildStartPlan111(plan)
}
public func exactServiceChildAllowed(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    httpServiceChildAllowed(parent, child) || channelServiceChildAllowed(parent, child) || httpStreamServiceChildAllowed(parent, child) || readViewServiceChildAllowed(parent, child) || pluginDocumentParentAllows(parent, child) || pluginChildParentAllows111(parent, child)
}
public func exactServiceRequestKey(parentCallId: String, child: NormalizedOperationPlan): String {
    let prefix = if (child.toolName == HOST_PLUGIN_CHILD_TOOL111) { "child-service:" }
        else if (child.toolName == HOST_CHANNEL_WRITE_TOOL) { "channel-service:" }
        else if (child.toolName == HOST_PLUGIN_DOCUMENT_TOOL) { "document-service:" }
        else if (child.toolName == HOST_HTTP_STREAM_TOOL) { "http-stream-service:" } else { "javascript-service:" }
    prefix + parentCallId + ":" + httpIntentText(child.canonicalArguments.field("intent").getOrThrow(), "id")
}

func channelIntentNeverReplay(plan: NormalizedOperationPlan): Bool {
    plan.effectClass == OperationEffectClass.ExternalMutation && plan.retryDisposition == OperationRetryDisposition.Never &&
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
}
public func channelIntentIdentifier(value: String): Bool {
    payload.channelIntentIdentifier(value)
}
func channelIntentHex(byte: Byte): Int64 {
    if (byte >= b'0' && byte <= b'9') { return Int64(byte - b'0') }
    if (byte >= b'a' && byte <= b'f') { return Int64(byte - b'a') + 10 }
    -1
}
func channelIntentError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
