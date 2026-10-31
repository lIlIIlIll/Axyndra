package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*


import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// One optional operator section in the existing services.json. It grants only
// exact ordinary contributions; aliases are arbitrary data, not host business.


public func hostPreparePluginReadonlyDelegation(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall): Result<AgentValue> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let descriptor = match (host.servicePackageData81(namespace, generation)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    if (descriptor.entryKind != PluginEntryKind.NativeExecutable || !descriptor.requestedCapabilities.contains("tool.readonly") ||
        call.name != "plugin." + namespace + "." + contribution) {
        return hostPluginResourceError("readonly_delegation.identity_invalid", "readonly delegation requires its actual native contribution") }
    let config = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    var selected: ?AgentValue = None
    for (grant in config.readonlyDelegations.items where httpIntentText(grant, "contribution") == contribution) { selected = Some(grant) }
    let grant = match (selected) { case Some(value) => value
        case None => return hostPluginResourceError("readonly_delegation.grant_missing", "operator has not granted this exact delegation contribution") }
    let snapshot = match (context.toolSetSnapshot) { case Some(value) => value
        case None => return hostPluginResourceError("readonly_delegation.snapshot_missing", "delegation requires the actual Run catalog snapshot") }
    match (snapshot.threadId) { case Some(thread) => if (thread.value != context.sessionId.value) {
        return hostPluginResourceError("readonly_delegation.thread_mismatch", "catalog snapshot belongs to another Thread") }; case None => () }
    let entries = ArrayList<AgentValue>()
    for (target in grant.field("tools").getOrThrow().items) {
        let targetNamespace = httpIntentText(target, "plugin"); let targetContribution = httpIntentText(target, "contribution")
        let name = "plugin." + targetNamespace + "." + targetContribution
        if (name == call.name) { return hostPluginResourceError("readonly_delegation.recursion_denied", "delegation cannot target itself") }
        let targetGeneration = host.instanceGeneration(targetNamespace)
        let actual = match (host.servicePackageData81(targetNamespace, targetGeneration)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        // First admitted tree shape is deliberately finite: this contribution
        // may create only its exact host read-view worker child.
        if (actual.entryKind != PluginEntryKind.NativeExecutable || !actual.requestedCapabilities.contains("process.readview")) {
            return hostPluginResourceError("readonly_delegation.target_unsupported", "delegation target requires the exact read-view protocol") }
        for (cap in actual.requestedCapabilities where cap != "process.readview" && cap != "workspace.read") {
            return hostPluginResourceError("readonly_delegation.target_unsupported", "delegation target requests another service or effect") }
        let targetConfig = match (loadHostPluginHttpConfiguration(settingsRoot, targetNamespace, actual.contentDigest)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (targetConfig.digest != config.digest || !targetConfig.ordinaryReadTools.contains(targetContribution)) {
            return hostPluginResourceError("readonly_delegation.target_not_read_granted", "target needs its own exact operator ordinary-read grant") }
        let version = match (host.instanceExecutorVersion(targetNamespace, targetGeneration)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        var found: ?ToolSnapshotEntry = None
        for (entry in snapshot.entries where entry.name == name) { found = Some(entry) }
        let entry = match (found) { case Some(value) => value
            case None => return hostPluginResourceError("readonly_delegation.target_not_exported", "target is absent from the actual Run catalog snapshot") }
        if (!entry.availableAtSnapshot || entry.executorVersion != version ||
            entry.implementationFingerprint != targetNamespace + ":" + actual.contentDigest) {
            return hostPluginResourceError("readonly_delegation.target_stale", "target publication differs from the actual Run snapshot") }
        entries.add(objectValue([ValueField("alias", textValue(httpIntentText(target, "alias"))), ValueField("name", textValue(name)),
            ValueField("version", textValue(entry.executorVersion)), ValueField("fingerprint", textValue(entry.implementationFingerprint)),
            ValueField("schema_digest", textValue(entry.schemaDigest)), ValueField("package_digest", textValue(actual.contentDigest)),
            ValueField("generation", textValue(targetGeneration.toString())), ValueField("services", listValue([textValue("process.readview")]))]))
    }
    match (config.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let payload = config.toolPayloadLimits(contribution)
    let maximum = match (payload) { case Some(value) => value.maxInputBytes; case None => 262144 }
    let frozenInput = try { parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: maximum) }
        catch (_: Exception) { return hostPluginResourceError("readonly_delegation.input_invalid", "delegation input exceeds its bounded JSON envelope") }
    let hostFields = ArrayList<ValueField>([ValueField("version", textValue(HOST_READONLY_DELEGATION_VERSION)),
            ValueField("plugin", textValue(namespace)), ValueField("package_digest", textValue(descriptor.contentDigest)),
            ValueField("generation", textValue(generation.toString())), ValueField("configuration_digest", textValue(config.digest)),
            ValueField("contribution", textValue(contribution)), ValueField("tool_set_id", textValue(snapshot.id)),
            ValueField("tools", listValue(entries.toArray())), ValueField("max_calls", integerValue(readonlyDelegationInteger(grant, "max_calls"))),
            ValueField("max_depth", integerValue(readonlyDelegationInteger(grant, "max_depth")))])
    match (payload) { case Some(value) => hostFields.add(ValueField("tool_payload_limits", value.value())); case None => () }
    match (config.inputAttachment(contribution)) {
        case Some(profile) =>
            let declared = match (host.toolInputAttachmentDeclaration(namespace, contribution, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (canonicalAgentValue(profile) != canonicalAgentValue(declared)) {
                return hostPluginResourceError("input_attachment.declaration_changed", "operator selector differs from the actual installed Tool declaration")
            }
            let text = match (frozenInput.field(httpIntentText(profile, "field"))) { case Some(value) => value
                case None => return hostPluginResourceError("input_attachment.text_missing", "attachment requires its exact frozen top-level text field") }
            if (text.unifiedKind != ValueKind.Text || text.text.size > readonlyDelegationInteger(profile, "max_bytes")) {
                return hostPluginResourceError("input_attachment.text_invalid", "attachment field is not bounded UTF8 text")
            }
            hostFields.add(ValueField("input_attachment", profile))
        case None => ()
    }
    match(grant.field("file_plan_proposals")){
        case Some(value)=>hostFields.add(ValueField("file_plan_proposals",value))
        case None=>()}
    Result.Ok(objectValue([ValueField("input", frozenInput), ValueField("host_plan", objectValue(hostFields.toArray()))]))
}

// Called after the Host canonicalizer has frozen its exact operator targets.
// Each child QName is an independent requirement of this parent, not a grant.
public func hostPluginReadonlyDelegationCapabilities(call: ToolCall): Array<Capability> {
    let host = match (call.arguments.field("host_plan")) { case Some(value) => value; case None => return [] }
    let entries = match (host.field("tools")) { case Some(value) => value; case None => return [] }
    if (httpIntentText(host, "version") != HOST_READONLY_DELEGATION_VERSION ||
        call.name != "plugin." + httpIntentText(host, "plugin") + "." + httpIntentText(host, "contribution") ||
        entries.unifiedKind != ValueKind.List || entries.items.size > 32) { return [] }
    let caps = ArrayList<Capability>(); let seen = HashSet<String>()
    for (entry in entries.items) {
        let name = httpIntentText(entry, "name")
        if (!name.startsWith("plugin.") || name == call.name || seen.contains(name)) { return [] }
        seen.add(name); caps.add(Capability(CapabilityKind.ExtensionInvoke, resource: name))
    }
    caps.toArray()
}

public func hostValidatePluginReadonlyDelegation(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    prepared: PreparedToolInvocation): Result<AgentValue> {
    if (!isFrozenReadonlyDelegationParentPlan(prepared.operationPlan) || prepared.source.kind == PreparedInvocationSourceKind.Derived ||
        prepared.source.operationRoot.isNone() || prepared.operationPlan.toolName != prepared.call.name) {
        return hostPluginResourceError("readonly_delegation.root_invalid", "delegation requires its actual frozen canonical root") }
    let input = prepared.operationPlan.canonicalArguments.field("input").getOrThrow()
    let actual = match (hostPreparePluginReadonlyDelegation(host, settingsRoot, namespace, contribution, generation, context,
        ToolCall(prepared.call.callId, prepared.call.name, input))) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    if (canonicalAgentValue(actual) != canonicalAgentValue(prepared.operationPlan.canonicalArguments)) {
        return hostPluginResourceError("readonly_delegation.grant_changed", "operator allowlist, catalog or installed generation changed") }
    Result.Ok(input)
}
