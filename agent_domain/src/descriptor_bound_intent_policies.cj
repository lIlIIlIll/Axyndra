package agent_domain

import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// Selection uses the same frozen intent validators as the execution boundary.
// Dynamic strings in public return values must be independent of the live input.

public func resolverContextReadCapabilities(input: ToolResolverInput): Array<Capability> {
    input.domainProjection({ call => resolverCapabilityOutput(boundContextReadCapabilities(call)) })
}

private func boundContextReadCapabilities(call: ToolCall): Array<Capability> {
    if (httpIntentText(call.arguments,"schema")==PLUGIN_PEER_READ111) {
        let peer=Capability(CapabilityKind.PeerMessage)
        if (httpIntentText(call.arguments,"invocation_capability")=="peer.message") { return [peer] }
        return [peer,Capability(CapabilityKind.ExtensionInvoke,
            resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))] }
    let values = ArrayList<Capability>()
    if(httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA ||
        httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
        return [Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))]}
    if(pluginDocumentContextWindowReadRequestValid(call.arguments)){
        return [Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))]}
    if(pluginDocumentRowJournalReadRequestValid(call.arguments)){
        return [Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))]}
    if (pluginDocumentReadRequestValid(call.arguments)) {
        return [Capability(CapabilityKind.ExtensionInvoke,
            resource: httpIntentText(call.arguments.field("binding").getOrThrow(), "namespace"))]
    }
    if (contextReadResourcePlanValid(call.arguments)) {
        for (resource in call.arguments.field("resources").getOrThrow().items) {
            values.add(Capability(CapabilityKind.WorkspaceRead, resource: httpIntentText(resource, "source")))
            if (httpIntentText(resource, "kind") == "index") {
                for (entry in resource.field("entries").getOrThrow().items) {
                    let relative = httpIntentText(entry, "relative")
                    values.add(Capability(CapabilityKind.WorkspaceRead, resource: if (relative == "") { httpIntentText(resource, "source") }
                        else { Path(httpIntentText(resource, "source")).join(relative).toString() })) }
            }
            if (httpIntentText(resource, "kind") == "metadata") {
                for (entry in resource.field("entries").getOrThrow().items) {
                    values.add(Capability(CapabilityKind.WorkspaceRead,
                        resource: Path(httpIntentText(resource, "source")).join(httpIntentText(entry, "name")).toString())) }
            }
            if (httpIntentText(resource, "kind") == "absence") {
                values.add(Capability(CapabilityKind.WorkspaceRead, resource: httpIntentText(resource, "absence_parent"))) }
        }
    }
    if (values.isEmpty()) { values.add(Capability(CapabilityKind.WorkspaceRead)) }
    values.toArray()
}

public func resolverContextReadApproval(input: ToolResolverInput): ToolApprovalMetadata {
    input.domainProjection({ call => boundContextReadApproval(call) })
}

private func boundContextReadApproval(call: ToolCall): ToolApprovalMetadata {
    if(httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA ||
        httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
        return ToolApprovalMetadata("extension.invoke",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Read this explicitly configured structural journal through the actual typed Provider"]),
            ApprovalGrantScope("extension.invoke",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false)}
    if(pluginDocumentContextWindowReadRequestValid(call.arguments)){
        return ToolApprovalMetadata("extension.invoke",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Read this explicitly configured window for the actual context Provider"]),
            ApprovalGrantScope("extension.invoke",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false)}
    if(pluginDocumentRowJournalReadRequestValid(call.arguments)){
        return ToolApprovalMetadata("extension.invoke",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Read this explicitly configured journal window before preparing the pending Tool"]),
            ApprovalGrantScope("extension.invoke",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false)}
    if (pluginDocumentReadRequestValid(call.arguments)) {
        return ToolApprovalMetadata("extension.invoke", RiskAssessment(ApprovalRiskLevel.Medium,
            flags: ["exact_context_read"], reasons: ["Read these operator-authorized logical documents before preparing this Tool"]),
            ApprovalGrantScope("extension.invoke", toolName: HOST_CONTEXT_READ_TOOL), sessionApprovalAllowed: false)
    }
    if (httpIntentText(call.arguments,"schema")==PLUGIN_PEER_READ111) {
        return ToolApprovalMetadata("peer.message",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Observe this actual same-root member before freezing its new invocation"]),
            ApprovalGrantScope("peer.message",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false) }
    var label = "workspace.read"; var risk = ApprovalRiskLevel.Medium
    let reasons = ArrayList<String>(["Read these frozen resources into this Run before preparing the pending tool"])
    if (contextReadResourcePlanValid(call.arguments)) {
        for (resource in call.arguments.field("resources").getOrThrow().items) {
            let permission = httpIntentText(resource, "permission")
            if (risk != ApprovalRiskLevel.Critical && permission != "workspace.read") { label = resolverOutputText(permission) }
            if (permission == "sensitive-path.read") { label = resolverOutputText(permission); risk = ApprovalRiskLevel.Critical }
            if (reasons.size < 10) { reasons.add(permission + ": " + httpIntentText(resource, "source")) }
            if (["metadata", "index"].contains(httpIntentText(resource, "kind"))) {
                for (entry in resource.field("entries").getOrThrow().items) {
                    let classified = httpIntentText(entry, "permission")
                    if (risk != ApprovalRiskLevel.Critical && classified != "workspace.read") { label = resolverOutputText(classified) }
                    if (classified == "sensitive-path.read") { label = resolverOutputText(classified); risk = ApprovalRiskLevel.Critical }
                    if (classified != "workspace.read" && reasons.size < 10) {
                        reasons.add(classified + ": " + Path(httpIntentText(resource, "source")).join((if (httpIntentText(resource, "kind") == "index") { httpIntentText(entry, "relative") } else { httpIntentText(entry, "name") })).toString()) }
                }
            }
        }
    }
    ToolApprovalMetadata(label, RiskAssessment(risk, flags: ["exact_context_read"], reasons: reasons.toArray()),
        ApprovalGrantScope(label, toolName: HOST_CONTEXT_READ_TOOL), sessionApprovalAllowed: false)
}

public func resolverPluginReadViewSideEffect(input: ToolResolverInput): Bool {
    input.domainProjection({ call => boundPluginReadViewSideEffect(call) })
}

private func boundPluginReadViewSideEffect(call: ToolCall): Bool {
    let host = match (call.arguments.field("host_plan")) { case Some(value) => value; case None => return true }
    if (httpIntentText(host, "version") != HOST_READ_VIEW_VERSION) { return true }
    let intents = match (host.field("intents")) { case Some(value) => value; case None => return true }
    if (intents.unifiedKind != ValueKind.List || intents.items.size != 1 ||
        readViewChildArguments(call.arguments, httpIntentText(intents.items[0], "id")).isError()) { return true }
    !host.field("read_granted").getOrThrow().asBool() || intents.items[0].field("requires_approval").getOrThrow().asBool()
}

public func resolverPluginReadViewCapabilities(input: ToolResolverInput): Array<Capability> {
    input.domainProjection({ call => resolverCapabilityOutput(boundPluginReadViewCapabilities(call)) })
}

private func boundPluginReadViewCapabilities(call: ToolCall): Array<Capability> {
    let host = match (call.arguments.field("host_plan")) { case Some(value) => value; case None => return [] }
    let intents = match (host.field("intents")) { case Some(value) => value; case None => return [] }
    if (intents.unifiedKind != ValueKind.List || intents.items.size != 1) { return [] }
    match (readViewChildArguments(call.arguments, httpIntentText(intents.items[0], "id"))) {
        case Result.Ok(value) =>
            let exact = readViewRequiredCapabilities(value)
            if (host.field("read_granted").getOrThrow().asBool()) { exact }
            else { let values = ArrayList<Capability>([Capability(CapabilityKind.WorkspaceRead)]); values.add(all: exact); values.toArray() }
        case Result.Err(_) => []
    }
}

public func resolverPluginReadViewApprovalMetadata(input: ToolResolverInput): ToolApprovalMetadata {
    input.domainProjection({ call => boundPluginReadViewApprovalMetadata(call) })
}

private func boundPluginReadViewApprovalMetadata(call: ToolCall): ToolApprovalMetadata {
    var label = "extension.invoke"; var level = ApprovalRiskLevel.High
    let reasons = ArrayList<String>(["Execute this exact installed package contribution using only the frozen read-resource view"])
    match (call.arguments.field("host_plan")) {
        case Some(host) => match (host.field("intents")) {
            case Some(intents) => if (intents.unifiedKind == ValueKind.List && intents.items.size == 1) {
                match (intents.items[0].field("resources")) {
                    case Some(resources) => for (resource in resources.items) {
                        let permission = httpIntentText(resource, "permission")
                        if (permission != "workspace.read") {
                            if (level != ApprovalRiskLevel.Critical) { label = resolverOutputText(permission) }
                            if (permission == "sensitive-path.read") { label = resolverOutputText(permission); level = ApprovalRiskLevel.Critical }
                            if (reasons.size < 10) { reasons.add(permission + ": " + httpIntentText(resource, "source")) }
                        }
                    }
                    case None => ()
                }
            }
            case None => ()
        }
        case None => ()
    }
    ToolApprovalMetadata(label, RiskAssessment(level, flags: ["exact_read_view"], reasons: reasons.toArray()),
        ApprovalGrantScope(label, toolName: resolverOutputText(call.name)), sessionApprovalAllowed: false)
}

public func resolverPluginReadonlyDelegationCapabilities(input: ToolResolverInput): Array<Capability> {
    input.domainProjection({ call => resolverCapabilityOutput(boundPluginReadonlyDelegationCapabilities(call)) })
}

private func boundPluginReadonlyDelegationCapabilities(call: ToolCall): Array<Capability> {
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

public func resolverPluginHttpRootNetworkPolicy(input: ToolResolverInput, namespace: String, packageDigest: String): Result<NetworkPolicy> {
    input.domainProjection({ call => resolverPolicyOutput(boundPluginHttpRootNetworkPolicy(call, namespace, packageDigest)) })
}

private func boundPluginHttpRootNetworkPolicy(call: ToolCall, namespace: String, packageDigest: String): Result<NetworkPolicy> {
    // ToolPipeline checks a caller's input before canonicalization. Raw input
    // grants nothing; canonicalization always wraps and recomputes it, even if
    // the caller happens to use the same field names as this host envelope.
    if (!httpIntentExactFields(call.arguments, ["input", "configuration", "host_plan"])) {
        return Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
    }
    let host = call.arguments.field("host_plan").getOrThrow()
    if (httpIntentText(host, "version") != HOST_HTTP_INTENT_VERSION ||
        httpIntentText(host, "plugin") != namespace || httpIntentText(host, "package_digest") != packageDigest) {
        return Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
    }
    let intents = match (host.field("intents")) {
        case Some(value) => value
        case None => return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "http.parent_invalid", "HTTP preparation omitted its intents"))
    }
    if (intents.unifiedKind != ValueKind.List || intents.items.size > 4) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "http.parent_invalid", "HTTP preparation has invalid intents"))
    }
    let rules = ArrayList<NetworkEgressRule>()
    for (intent in intents.items) {
        match (httpServiceChildArguments(call.arguments, httpIntentText(intent, "id"))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let policy = match (httpIntentPolicy(intent)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        rules.add(policy.egress[0])
    }
    if (rules.isEmpty()) { Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) } else {
        normalizeNetworkPolicy(NetworkPolicyMode.Mediated, egress: rules.toArray())
    }
}

// The Host checks its live generation, configuration and per-key permissions.
// Only the selected document keys cross the data-only callback boundary.
public func resolverDocumentReadKeys(input: ToolResolverInput, namespace: String,
    packageDigest: String, generation: UInt64, configurationDigest: String,
    implementation: String, schemaDigest: String): ?Array<String> {
    input.domainProjection({ call =>
        let frozen = call.arguments.field("host_plan").getOrThrow()
        let intents = frozen.field("intents").getOrThrow()
        if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty() || intents.items.size > 8) { return None }
        let selected = match (pluginDocumentChildArguments(call.arguments, httpIntentText(intents.items[0], "id"))) {
            case Result.Err(_) => return None; case Result.Ok(value) => value }
        let binding = selected.field("binding").getOrThrow()
        if (httpIntentText(binding, "namespace") != namespace || httpIntentText(binding, "package_digest") != packageDigest ||
            httpIntentText(binding, "generation") != generation.toString() || httpIntentText(binding, "configuration_digest") != configurationDigest ||
            httpIntentText(binding, "contribution") != call.name || httpIntentText(binding, "implementation_fingerprint") != implementation ||
            httpIntentText(binding, "schema_digest") != schemaDigest) { return None }
        let keys = ArrayList<String>()
        for (intent in intents.items) {
            if (httpIntentText(intent, "mode") != "read") { return None }
            keys.add(resolverOutputText(httpIntentText(intent, "key")))
        }
        Some(keys.toArray())
    })
}
