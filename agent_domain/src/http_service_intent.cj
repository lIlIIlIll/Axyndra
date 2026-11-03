package agent_domain

import logical_json_payload as payload

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Protocol-neutral HTTP request data, not a provider adapter or a grant. A
// request becomes executable only after the host binds it to an operator
// configuration and a canonical parent Operation. Both the broker and Store
// use the same exact-intent predicate at the derived admission boundary.
public let HOST_HTTP_SERVICE_TOOL = "host.network.http"
public let HOST_HTTP_INTENT_VERSION = "http-intents/v1"
public let HOST_HTTP_REQUEST_MAX_BYTES: Int64 = 65536
public let HOST_HTTP_RESPONSE_MAX_BYTES: Int64 = 65536

public class HttpServiceEndpoint {
    public let url: String
    public let host: String
    public let port: UInt16
    public let secure: Bool

    init(url: String, host: String, port: UInt16, secure: Bool) {
        this.url = url
        this.host = host
        this.port = port
        this.secure = secure
    }
}

public func httpServiceEndpoint(url: String): Result<HttpServiceEndpoint> {
    if (url.size < 8 || url.size > 4096 || url.contains("\\") ||
        url.contains("@") || url.contains("?") || url.contains("#")) {
        return httpIntentError("http.url_invalid", "HTTP URL must have a bounded explicit origin and path, without credentials, query, or fragment")
    }
    for (byte in url.toArray() where byte < 33u8 || byte > 126u8) {
        return httpIntentError("http.url_invalid", "HTTP URL must contain visible ASCII bytes; query values are separate fields")
    }
    let secure = url.startsWith("https://")
    if (!secure && !url.startsWith("http://")) {
        return httpIntentError("http.url_invalid", "HTTP service supports only http and https")
    }
    let offset: Int64 = if (secure) { 8 } else { 7 }
    let remainder = url[offset..]
    let slash = match (remainder.indexOf("/")) {
        case Some(value) => value
        case None => return httpIntentError("http.url_invalid", "HTTP URL requires an explicit absolute path")
    }
    if (slash == 0) { return httpIntentError("http.url_invalid", "HTTP URL requires an origin") }
    let authority = remainder[..slash]
    let host: String
    var portText = ""
    if (authority.startsWith("[")) {
        let close = match (authority.indexOf("]")) {
            case Some(value) => value
            case None => return httpIntentError("http.url_invalid", "IPv6 HTTP origin must be bracketed")
        }
        if (close <= 1) { return httpIntentError("http.url_invalid", "HTTP origin is empty") }
        host = authority[1..close]
        for (byte in host.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
            (byte >= 97u8 && byte <= 102u8) || byte == 58u8 || byte == 46u8)) {
            return httpIntentError("http.url_invalid", "HTTP IPv6 origin must be a lowercase address without a zone")
        }
        let suffix = authority[close + 1..]
        if (suffix != "") {
            if (!suffix.startsWith(":")) { return httpIntentError("http.url_invalid", "invalid HTTP origin suffix") }
            portText = suffix[1..]
            if (portText == "") { return httpIntentError("http.url_invalid", "HTTP port is empty") }
        }
    } else {
        let parts = authority.split(":")
        if (parts.size < 1 || parts.size > 2 || parts[0] == "") {
            return httpIntentError("http.url_invalid", "HTTP origin is invalid")
        }
        host = parts[0]
        if (host.endsWith(".") || host.startsWith(".") || host.contains("..")) {
            return httpIntentError("http.url_invalid", "HTTP host must be canonical")
        }
        for (byte in host.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
            (byte >= 97u8 && byte <= 122u8) || byte == 45u8 || byte == 46u8)) {
            return httpIntentError("http.url_invalid", "HTTP host must be lowercase ASCII without credentials or escapes")
        }
        if (parts.size == 2) {
            portText = parts[1]
            if (portText == "") { return httpIntentError("http.url_invalid", "HTTP port is empty") }
        }
    }
    var port = if (secure) { 443u16 } else { 80u16 }
    if (portText != "") {
        for (byte in portText.toArray() where byte < 48u8 || byte > 57u8) {
            return httpIntentError("http.url_invalid", "HTTP port must be decimal")
        }
        let parsed = try { Int64.parse(portText) } catch (_: Exception) {
            return httpIntentError("http.url_invalid", "HTTP port is out of range")
        }
        if (parsed < 1 || parsed > 65535 || parsed.toString() != portText) {
            return httpIntentError("http.url_invalid", "HTTP port must be canonical and in range")
        }
        port = UInt16(parsed)
    }
    Result.Ok(HttpServiceEndpoint(url, host, port, secure))
}

public func httpIntentText(value: AgentValue, name: String): String {
    payload.httpIntentText(value, name)
}

public func httpIntentExactFields(value: AgentValue, names: Array<String>): Bool {
    payload.httpIntentExactFields(value, names)
}

public func httpIntentIdentifier(value: String): Bool {
    payload.httpIntentIdentifier(value)
}

public func httpServicePluginNamespace(value: String): Bool {
    let parts = value.split(":")
    parts.size == 2 && parts[0] == "axyndra" && httpIntentIdentifier(parts[1])
}

public func httpServicePackageDigest(value: String): Bool {
    // This is the existing PluginPackageDescriptor content identity, including
    // its algorithm tag. Configuration digests use the separate raw SHA form.
    value.startsWith("sha256:") && httpIntentDigest(value[7..])
}

public func validateHttpServiceRequest(value: AgentValue): Result<Unit> {
    if (!httpIntentExactFields(value, ["method", "url", "query", "headers", "json_body", "credential_refs", "timeout_ms"]) ||
        canonicalAgentValue(value).size > HOST_HTTP_REQUEST_MAX_BYTES) {
        return httpIntentError("http.request_invalid", "HTTP request has unknown, missing, repeated, or oversized fields")
    }
    let method = httpIntentText(value, "method")
    if (method != "GET" && method != "POST") {
        return httpIntentError("http.method_invalid", "HTTP service supports GET and POST only")
    }
    match (httpServiceEndpoint(httpIntentText(value, "url"))) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    let body = value.field("json_body").getOrThrow()
    if ((method == "GET" && body.unifiedKind != ValueKind.Null) ||
        (method == "POST" && body.unifiedKind != ValueKind.Object)) {
        return httpIntentError("http.body_invalid", "GET has no body; POST requires a JSON object")
    }
    for (name in ["query", "headers"]) {
        let values = value.field(name).getOrThrow()
        if (values.unifiedKind != ValueKind.Object || values.fields.size > 32) {
            return httpIntentError("http.fields_invalid", "HTTP query and headers must be bounded objects")
        }
        let seen = ArrayList<String>()
        for (field in values.fields) {
            let key = if (name == "headers") { field.name.toAsciiLower() } else { field.name }
            if (field.name == "" || field.name.size > 128 || field.value.unifiedKind != ValueKind.Text ||
                seen.contains(key) || field.value.text.contains("\u{0000}")) {
                return httpIntentError("http.fields_invalid", "HTTP field is invalid or repeated")
            }
            seen.add(key)
            if (name == "headers") {
                if (!httpServiceHeaderAllowed(key)) {
                    return httpIntentError("http.header_forbidden", "HTTP header is controlled by the host")
                }
                for (byte in field.value.text.toArray() where byte < 32u8 || byte == 127u8) {
                    return httpIntentError("http.fields_invalid", "HTTP header values must not contain controls")
                }
            }
        }
    }
    let refs = value.field("credential_refs").getOrThrow()
    if (refs.unifiedKind != ValueKind.List || refs.items.size > 4) {
        return httpIntentError("http.credential_refs_invalid", "HTTP request accepts at most four opaque credential references")
    }
    let seenRefs = ArrayList<String>()
    for (item in refs.items) {
        if (item.unifiedKind != ValueKind.Text || !httpIntentIdentifier(item.text) || seenRefs.contains(item.text)) {
            return httpIntentError("http.credential_refs_invalid", "HTTP credential reference is invalid or repeated")
        }
        seenRefs.add(item.text)
    }
    let timeout = value.field("timeout_ms").getOrThrow()
    if (timeout.unifiedKind != ValueKind.Number) {
        return httpIntentError("http.timeout_invalid", "HTTP timeout must be an integer")
    }
    let millis = try { Int64.parse(timeout.asNumberText()) } catch (_: Exception) { 0 }
    if (millis < 1 || millis > 120000) {
        return httpIntentError("http.timeout_invalid", "HTTP timeout must be from 1 to 120000 milliseconds")
    }
    Result.Ok(())
}

public func httpServiceHeaderAllowed(name: String): Bool {
    if (name == "" || name.size > 128) { return false }
    for (byte in name.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
        (byte >= 97u8 && byte <= 122u8) || byte == 45u8)) { return false }
    !["host", "authorization", "cookie", "cookie2", "connection", "transfer-encoding",
        "content-length", "expect", "accept-encoding", "te", "trailer", "upgrade"].contains(name) &&
        !name.startsWith("proxy-") && !name.startsWith("sec-")
}

public func httpServiceChildArguments(parent: AgentValue, id: String): Result<AgentValue> {
    if (!httpIntentExactFields(parent, ["input", "configuration", "host_plan"])) {
        return httpIntentError("http.parent_invalid", "HTTP child requires a frozen host preparation")
    }
    let host = parent.field("host_plan").getOrThrow()
    if (!httpIntentExactFields(host, ["version", "plugin", "package_digest", "generation", "configuration_digest", "intents"]) ||
        httpIntentText(host, "version") != HOST_HTTP_INTENT_VERSION ||
        !httpServicePluginNamespace(httpIntentText(host, "plugin")) ||
        !httpServicePackageDigest(httpIntentText(host, "package_digest")) ||
        !httpIntentDigest(httpIntentText(host, "configuration_digest"))) {
        return httpIntentError("http.parent_invalid", "HTTP host preparation identity is invalid")
    }
    let generation = httpIntentText(host, "generation")
    let parsed = try { UInt64.parse(generation) } catch (_: Exception) { 0u64 }
    if (parsed == 0u64 || parsed.toString() != generation) {
        return httpIntentError("http.parent_invalid", "HTTP host generation is invalid")
    }
    let intents = host.field("intents").getOrThrow()
    if (intents.unifiedKind != ValueKind.List || intents.items.size > 4) {
        return httpIntentError("http.parent_invalid", "HTTP host preparation exceeds the intent bound")
    }
    let seen = ArrayList<String>()
    var selected: ?AgentValue = None
    for (intent in intents.items) {
        let key = httpIntentText(intent, "id")
        if (!httpIntentExactFields(intent, ["id", "request", "network"]) ||
            !httpIntentIdentifier(key) || seen.contains(key)) {
            return httpIntentError("http.parent_invalid", "HTTP host intent is invalid or repeated")
        }
        seen.add(key)
        match (validateHttpServiceRequest(intent.field("request").getOrThrow())) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (httpIntentPolicy(intent)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        if (key == id) { selected = Some(intent) }
    }
    let intent = match (selected) {
        case Some(value) => value
        case None => return httpIntentError("http.intent_missing", "HTTP intent is absent from the frozen parent plan")
    }
    Result.Ok(objectValue([
        ValueField("plugin", host.field("plugin").getOrThrow()),
        ValueField("generation", host.field("generation").getOrThrow()),
        ValueField("package_digest", host.field("package_digest").getOrThrow()),
        ValueField("configuration_digest", host.field("configuration_digest").getOrThrow()),
        ValueField("intent", intent)
    ]))
}

public func httpIntentPolicy(intent: AgentValue): Result<NetworkPolicy> {
    let request = match (intent.field("request")) {
        case Some(value) => value
        case None => return httpIntentError("http.intent_invalid", "HTTP intent omitted its request")
    }
    let endpoint = match (httpServiceEndpoint(httpIntentText(request, "url"))) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let policy = match (intent.field("network")) {
        case Some(value) => match (parseNetworkPolicy(value)) {
            case Result.Ok(parsed) => parsed
            case Result.Err(error) => return Result.Err(error)
        }
        case None => return httpIntentError("http.intent_invalid", "HTTP intent omitted its network policy")
    }
    if (policy.mode != NetworkPolicyMode.Mediated || policy.egress.size != 1 || !policy.publish.isEmpty() ||
        policy.egress[0].host != endpoint.host || policy.egress[0].port != endpoint.port) {
        return httpIntentError("http.intent_network_invalid", "HTTP intent must mediate exactly its own origin")
    }
    Result.Ok(policy)
}

public func isHttpServiceChildPlan(child: NormalizedOperationPlan): Bool {
    if (child.toolName != HOST_HTTP_SERVICE_TOOL || child.implementation.implementationFingerprint != "host-http-intent-v1" ||
        !httpIntentExactFields(child.canonicalArguments, ["plugin", "generation", "package_digest", "configuration_digest", "intent"]) ||
        child.retryDisposition != OperationRetryDisposition.Never ||
        match (child.replayDisposition) { case ReplayDisposition.NeverReplay => false; case _ => true }) { return false }
    let intent = child.canonicalArguments.field("intent").getOrThrow()
    if (!httpIntentExactFields(intent, ["id", "request", "network"]) || !httpIntentIdentifier(httpIntentText(intent, "id"))) { return false }
    let request = intent.field("request").getOrThrow()
    match (validateHttpServiceRequest(request)) { case Result.Err(_) => return false; case Result.Ok(_) => () }
    let policy = match (httpIntentPolicy(intent)) { case Result.Err(_) => return false; case Result.Ok(value) => value }
    if (!networkPoliciesEqual(policy, child.networkPolicy) || child.effectClass !=
        if (httpIntentText(request, "method") == "GET") { OperationEffectClass.ReadOnly } else { OperationEffectClass.ExternalMutation }) { return false }
    let resource = networkEgressResource(policy.egress[0])
    if (child.requiredCapabilities.size != 1 || child.requiredCapabilities[0].kind != CapabilityKind.NetworkAccess ||
        child.requiredCapabilities[0].resource != resource) { return false }
    true
}

public func httpServiceChildAllowed(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    if (!isHttpServiceChildPlan(child)) { return false }
    let args = child.canonicalArguments
    let namespace = httpIntentText(args, "plugin")
    if (!parent.toolName.startsWith("plugin." + namespace + ".") ||
        parent.implementation.implementationFingerprint != namespace + ":" + httpIntentText(args, "package_digest") ||
        parent.networkPolicy.mode != NetworkPolicyMode.Mediated || !parent.networkPolicy.publish.isEmpty() ||
        parent.effectClass != OperationEffectClass.ExternalMutation ||
        parent.retryDisposition != OperationRetryDisposition.Never ||
        match (parent.replayDisposition) { case ReplayDisposition.NeverReplay => false; case _ => true }) { return false }
    let expected = match (httpServiceChildArguments(parent.canonicalArguments,
        httpIntentText(args.field("intent").getOrThrow(), "id"))) {
        case Result.Ok(value) => value
        case Result.Err(_) => return false
    }
    if (canonicalAgentValue(expected) != canonicalAgentValue(args)) { return false }
    let ceiling = CapabilitySet(values: parent.requiredCapabilities)
    if (!ceiling.allows(CapabilityKind.ExtensionInvoke)) { return false }
    let rule = child.networkPolicy.egress[0]
    let resource = networkEgressResource(rule)
    if (!ceiling.allows(CapabilityKind.NetworkAccess, resource: resource)) { return false }
    // Capability wildcard semantics cannot substitute for this exact frozen
    // gateway rule, including the operator's explicit private-address set.
    for (allowed in parent.networkPolicy.egress where networkEgressResource(allowed) == resource) { return true }
    false
}

public func httpIntentDigest(value: String): Bool {
    payload.httpIntentDigest(value)
}

func httpIntentError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
