package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

public let HOST_PLUGIN_HTTP_CONFIGURATION_MAX_BYTES: Int64 = 262144
public let HOST_PLUGIN_HTTP_SECRET_MAX_BYTES: Int64 = 8192

// Secret-bearing values are host-internal and deliberately have no JSON codec.
public class HostPluginHttpCredentialValue {
    public let ref: String
    public let secret: String
    public let header: String
    public let jsonPointer: String
    public let headerPrefix: String
    public init(ref: String, secret: String, header: String, jsonPointer: String, headerPrefix!: String = "") {
        this.ref = ref; this.secret = secret; this.header = header; this.jsonPointer = jsonPointer
        this.headerPrefix = headerPrefix
    }
    public func headerValue(): String { headerPrefix + secret }
    public func redactedValues(): Array<String> {
        if (headerPrefix == "") { [secret] } else { [secret, headerValue()] }
    }
}

public class HostPluginHttpCredentialBinding {
    public let ref: String
    public let environment: String
    public let file: String
    public let header: String
    public let jsonPointer: String
    public let jsonField: String
    public let headerPrefix: String
    public init(ref: String, environment: String, file: String, header: String, jsonPointer: String, jsonField: String,
        headerPrefix!: String = "") {
        this.ref = ref; this.environment = environment; this.file = file
        this.header = header; this.jsonPointer = jsonPointer; this.jsonField = jsonField
        this.headerPrefix = headerPrefix
    }
}

public class HostPluginHttpRequestGrant {
    public let url: String
    public let methods: Array<String>
    public let refs: Array<String>
    public let network: NetworkPolicy
    public init(url: String, methods: Array<String>, refs: Array<String>, network: NetworkPolicy) {
        this.url = url; this.methods = methods; this.refs = refs; this.network = network
    }
}

public class HostPluginHttpConfiguration {
    private let configurationText: String
    public prop configuration: AgentValue { get() { parseUnifiedJson(configurationText, maxBytes: HOST_PLUGIN_HTTP_CONFIGURATION_MAX_BYTES) } }
    public let digest: String
    public let namespace: String
    public let packageDigest: String
    private let settingsRoot: String
    private let requests: Array<HostPluginHttpRequestGrant>
    private let credentials: Array<HostPluginHttpCredentialBinding>
    public let protocolLimits: ServiceProtocolLimits
    public let payloadLimits: ?ServicePayloadLimits
    private let readOnlyToolValues: Array<String>
    private let ordinaryReadToolValues: Array<String>
    private let deadlineText: String
    func readViewDeadlineMaximum(tool: String): ?Int64 {
        readViewDeadlineGrantMaximum(parseUnifiedJson(deadlineText, maxBytes: 16384), tool)
    }
    private let parameterContextToolValues: Array<String>
    func usesReadViewParameterContext(tool: String): Bool { parameterContextToolValues.contains(tool) }
    private let parameterReferenceToolValues: Array<String>
    public func usesReadViewParameterReference(tool: String): Bool { parameterReferenceToolValues.contains(tool) }
    private let toolPayloadText: String
    public func toolPayloadLimits(contribution: String): ?OrdinaryToolPayloadLimits {
        for (value in parseUnifiedJson(toolPayloadText, maxBytes: 65536).items) {
            let parsed = ordinaryToolPayloadLimitsFromValue(value).getOrThrow()
            if (parsed.contribution == contribution) { return Some(parsed) }
        }
        None
    }
    private let attachmentText: String
    public func inputAttachment(contribution: String): ?AgentValue {
        for (value in parseUnifiedJson(attachmentText, maxBytes: 65536).items where httpIntentText(value, "contribution") == contribution) {
            return Some(toolInputAttachmentProfileFromGrant(value))
        }
        None
    }
    private let delegationText: String
    public prop readonlyDelegations: AgentValue { get() { parseUnifiedJson(delegationText, maxBytes: 65536) } }
    public prop ordinaryReadTools: Array<String> { get() { ordinaryReadToolValues.clone() } }
    public prop readOnlyTools: Array<String> { get() { readOnlyToolValues.clone() } }

    init(settingsRoot: String, namespace: String, packageDigest: String, configuration: AgentValue,
        digest: String, requests: Array<HostPluginHttpRequestGrant>, credentials: Array<HostPluginHttpCredentialBinding>,
        readOnlyTools!: Array<String> = [], protocolLimits!: ServiceProtocolLimits = ServiceProtocolLimits(),
        ordinaryReadTools!: Array<String> = [], payloadLimits!: ?ServicePayloadLimits = None, readonlyDelegations!: AgentValue = listValue([]), toolPayloadLimits!: AgentValue = listValue([]), readViewParameterReferences!: Array<String> = [], toolInputAttachments!: AgentValue = listValue([]), readViewDeadlines!: AgentValue = listValue([]), readViewParameterContexts!: Array<String> = []) {
        this.settingsRoot = settingsRoot; this.namespace = namespace; this.packageDigest = packageDigest
        this.configurationText = stringifyUnifiedJson(configuration); this.digest = digest; this.requests = requests; this.credentials = credentials
        this.readOnlyToolValues = readOnlyTools.clone(); this.protocolLimits = protocolLimits
        this.ordinaryReadToolValues = ordinaryReadTools.clone(); this.payloadLimits = payloadLimits
        this.delegationText = stringifyUnifiedJson(readonlyDelegations)
        this.toolPayloadText = stringifyUnifiedJson(toolPayloadLimits)
        this.attachmentText = stringifyUnifiedJson(toolInputAttachments)
        this.deadlineText = stringifyUnifiedJson(readViewDeadlines)
        this.parameterReferenceToolValues = readViewParameterReferences.clone()
        this.parameterContextToolValues = readViewParameterContexts.clone()
    }

    public func stillCurrent(): Result<Unit> {
        match (readHostPluginHttpConfiguration(settingsRoot)) {
            case Result.Ok(source) => if (modelPolicySha256Text(source) == digest) { return Result.Ok(()) }
            case Result.Err(_) => ()
        }
        hostPluginHttpConfigError("plugin.http_configuration_changed", "operator HTTP configuration was removed or changed")
    }

    public func bindIntents(raw: AgentValue): Result<Array<AgentValue>> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!httpIntentExactFields(raw, ["intents"])) {
            return hostPluginHttpConfigError("plugin.http_intents_invalid", "pure preparation must return only intents")
        }
        let intents = raw.field("intents").getOrThrow()
        if (intents.unifiedKind != ValueKind.List || intents.items.size > 4) {
            return hostPluginHttpConfigError("plugin.http_intents_invalid", "pure preparation accepts at most four intents")
        }
        let seen = ArrayList<String>()
        let output = ArrayList<AgentValue>()
        for (intent in intents.items) {
            let id = httpIntentText(intent, "id")
            if (!httpIntentExactFields(intent, ["id", "request"]) || !httpIntentIdentifier(id) || seen.contains(id)) {
                return hostPluginHttpConfigError("plugin.http_intents_invalid", "HTTP intent identity or shape is invalid")
            }
            seen.add(id)
            let request = intent.field("request").getOrThrow()
            let grant = match (requestGrant(request)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            output.add(objectValue([
                ValueField("id", textValue(id)), ValueField("request", request),
                ValueField("network", networkPolicyCanonicalValue(grant.network))
            ]))
        }
        Result.Ok(output.toArray())
    }

    // Streaming requests retain their exact raw body. The existing operator
    // request/credential grants remain authoritative; JSON body injection is
    // rejected before any credential is resolved.
    public func bindStreamIntents(raw: AgentValue): Result<Array<AgentValue>> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let maximum = match (payloadLimits) { case Some(value) => value.maxPrepareBytes; case None => 196608 }
        if (!httpIntentExactFields(raw, ["intents"]) || stringifyUnifiedJson(raw).size > maximum) {
            return hostPluginHttpConfigError("http.stream_intents_invalid", "HTTP stream preparation must return bounded intents")
        }
        let intents = raw.field("intents").getOrThrow()
        if (intents.unifiedKind != ValueKind.List || intents.items.size > 4) {
            return hostPluginHttpConfigError("http.stream_intents_invalid", "HTTP stream accepts at most four intents")
        }
        let seen = HashSet<String>(); let output = ArrayList<AgentValue>()
        for (intent in intents.items) {
            let id = httpIntentText(intent, "id")
            if (!httpIntentExactFields(intent, ["id", "request"]) || !httpIntentIdentifier(id) || seen.contains(id)) {
                return hostPluginHttpConfigError("http.stream_intents_invalid", "HTTP stream intent identity is invalid or repeated")
            }
            seen.add(id)
            let request = intent.field("request").getOrThrow()
            // Pure plugin preparation supplies bytes, never artifact identities.
            if (request.field("body_payload").isSome()) { return hostPluginHttpConfigError("http.stream_payload_not_authored", "plugin cannot author host payload references") }
            let projection = match (streamGrantProjection(request)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
            let grant = match (requestGrant(projection)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
            output.add(parseUnifiedJson(stringifyUnifiedJson(objectValue([
                ValueField("id", textValue(id)), ValueField("request", request),
                ValueField("network", networkPolicyCanonicalValue(grant.network))])), maxBytes: maximum))
        }
        Result.Ok(output.toArray())
    }

    // Composition-only ModelAttempt projection. Timeouts belong to the
    // already claimed Attempt; URL/method/header/ref authorization is exactly
    // the same operator configuration. This DTO validation mints no authority.
    public func bindModelRequest(request: AgentValue): Result<NetworkPolicy> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (request.field("body_payload").isSome()) {
            return hostPluginHttpConfigError("http.stream_payload_not_authored", "provider cannot author host payload references")
        }
        let projection = match (modelCredentialProjection(request)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (requestGrant(projection)) { case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(value.network) }
    }
    public func modelCredentialProjection(request: AgentValue): Result<AgentValue> {
        streamGrantProjection(request, modelOwner: true)
    }

    // Host-only finite maintenance projection. Contains no secret values or
    // source locations; the same services.json digest and requestGrant checks
    // still decide every concrete exchange after actual maintenance handoff.
    public func streamMaintenanceGrants(): Result<AgentValue> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let values = ArrayList<AgentValue>()
        for (request in requests) {
            let injected = ArrayList<AgentValue>()
            for (ref in request.refs) {
                let binding = match (credential(ref)) {
                    case Some(value) => value
                    case None => return hostPluginHttpConfigError("http.stream_credential_denied", "maintenance credential is not configured")
                }
                if (binding.header == "" || binding.jsonPointer != "") {
                    return hostPluginHttpConfigError("http.stream_body_injection_denied", "stream maintenance only supports header credential injection")
                }
                let fields = ArrayList<ValueField>([ValueField("ref", textValue(ref)), ValueField("header", textValue(binding.header))])
                if (binding.headerPrefix != "") { fields.add(ValueField("prefix", textValue(binding.headerPrefix))) }
                injected.add(objectValue(fields.toArray()))
            }
            values.add(objectValue([ValueField("url", textValue(request.url)),
                ValueField("methods", listValue(request.methods.map({ item => textValue(item) }))),
                ValueField("credential_refs", listValue(request.refs.map({ item => textValue(item) }))),
                ValueField("credential_headers", listValue(injected.toArray())),
                ValueField("header_policy", textValue("http-service-headers/v1")),
                ValueField("network", networkPolicyCanonicalValue(request.network))]))
        }
        Result.Ok(listValue(values.toArray()))
    }

    public func resolveStreamCredentials(request: AgentValue): Result<Array<HostPluginHttpCredentialValue>> {
        let projection = match (streamGrantProjection(request)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        resolveCredentials(projection)
    }

    private func streamGrantProjection(request: AgentValue, modelOwner!: Bool = false): Result<AgentValue> {
        let maximum = match (payloadLimits) { case Some(value) => value.maxWriteBytes; case None => HOST_HTTP_STREAM_REQUEST_MAX_BYTES }
        let response = match (payloadLimits) { case Some(value) => if (modelOwner) { modelHttpWireMaximum(value.maxResultBytes) } else { value.maxResultBytes }; case None => HOST_HTTP_STREAM_RESPONSE_MAX_BYTES }
        match (validateHttpStreamRequest(request, maximumBytes: maximum, responseBytes: response, allowPayload: payloadLimits.isSome(),
            timeoutMaximum: if (modelOwner) { Int64.Max } else { 120000 }, allowZeroTimeout: modelOwner, modelEnvelope: modelOwner)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        for (ref in request.field("credential_refs").getOrThrow().items) {
            let binding = match (credential(ref.text)) {
                case Some(value) => value
                case None => return hostPluginHttpConfigError("http.stream_credential_denied", "HTTP stream credential is not configured")
            }
            if (binding.header == "" || binding.jsonPointer != "") {
                return hostPluginHttpConfigError("http.stream_body_injection_denied", "Exact HTTP stream bytes cannot use JSON body credential injection")
            }
        }
        let endpoint = httpStreamEndpoint(httpIntentText(request, "url")).value().getOrThrow()
        Result.Ok(objectValue([
            ValueField("method", request.field("method").getOrThrow()), ValueField("url", textValue(endpoint.url)),
            ValueField("headers", request.field("headers").getOrThrow()), ValueField("query", objectValue([])),
            ValueField("json_body", if (httpIntentText(request, "method") == "GET") { nullValue() } else { objectValue([]) }),
            ValueField("credential_refs", request.field("credential_refs").getOrThrow()),
            ValueField("timeout_ms", if (modelOwner) { integerValue(1) } else { request.field("timeout_ms").getOrThrow() })]))
    }

    // Call only after canonical admission. Loading and binding never read a
    // secret value, and all errors below intentionally omit exception text.
    public func resolveCredentials(request: AgentValue): Result<Array<HostPluginHttpCredentialValue>> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (requestGrant(request)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let result = ArrayList<HostPluginHttpCredentialValue>()
        for (value in request.field("credential_refs").getOrThrow().items) {
            let binding = credential(value.text).getOrThrow()
            let secret = if (binding.environment != "") {
                match (getVariable(binding.environment)) {
                    case Some(secret) => secret
                    case None => return hostPluginHttpConfigError("plugin.http_credential_unavailable", "configured HTTP credential is unavailable")
                }
            } else {
                let path = match (hostPluginHttpCredentialFile(settingsRoot, binding.file)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                match (readHostPluginHttpBoundedText(path, HOST_PLUGIN_HTTP_SECRET_MAX_BYTES)) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => return hostPluginHttpConfigError("plugin.http_credential_unavailable", "configured HTTP credential is unavailable or oversized")
                }
            }
            if (secret == "" || secret.size > HOST_PLUGIN_HTTP_SECRET_MAX_BYTES || secret.contains("\u{0000}") ||
                secret.contains("\r") || secret.contains("\n")) {
                return hostPluginHttpConfigError("plugin.http_credential_invalid", "HTTP credential must be nonempty, at most 8 KiB, and contain no NUL or line breaks")
            }
            if (binding.header != "") {
                if (binding.headerPrefix.size + secret.size > HOST_PLUGIN_HTTP_SECRET_MAX_BYTES) {
                    return hostPluginHttpConfigError("plugin.http_credential_invalid", "HTTP injected header exceeds its bound")
                }
                for (byte in secret.toArray() where byte < 32u8 || byte > 126u8) {
                    return hostPluginHttpConfigError("plugin.http_credential_invalid", "HTTP header credentials must contain visible ASCII only")
                }
            }
            result.add(HostPluginHttpCredentialValue(binding.ref, secret, binding.header, binding.jsonPointer, headerPrefix: binding.headerPrefix))
        }
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(result.toArray())
    }

    private func credential(ref: String): ?HostPluginHttpCredentialBinding {
        for (value in credentials where value.ref == ref) { return Some(value) }
        None
    }

    private func requestGrant(request: AgentValue): Result<HostPluginHttpRequestGrant> {
        match (validateHttpServiceRequest(request)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        for (grant in requests where grant.url == httpIntentText(request, "url") &&
            grant.methods.contains(httpIntentText(request, "method"))) {
            let targets = ArrayList<String>()
            for (ref in request.field("credential_refs").getOrThrow().items) {
                let binding = match (credential(ref.text)) {
                    case Some(value) => value
                    case None => return hostPluginHttpConfigError("plugin.http_credential_denied", "HTTP credential reference is not configured for this plugin")
                }
                if (!grant.refs.contains(ref.text)) {
                    return hostPluginHttpConfigError("plugin.http_credential_denied", "HTTP credential reference is not authorized for this request")
                }
                let target = if (binding.header != "") { "header:" + binding.header } else { "json:" + binding.jsonField }
                if (targets.contains(target)) {
                    return hostPluginHttpConfigError("plugin.http_credential_collision", "HTTP credential injection locations overlap")
                }
                targets.add(target)
                if (binding.header != "") {
                    for (field in request.field("headers").getOrThrow().fields where field.name.toAsciiLower() == binding.header) {
                        return hostPluginHttpConfigError("plugin.http_credential_collision", "HTTP credential cannot overwrite a request header")
                    }
                } else if (httpIntentText(request, "method") != "POST" ||
                    request.field("json_body").getOrThrow().field(binding.jsonField).isSome()) {
                    return hostPluginHttpConfigError("plugin.http_credential_collision", "HTTP JSON credential requires an absent top-level POST field")
                }
            }
            return Result.Ok(grant)
        }
        hostPluginHttpConfigError("plugin.http_request_denied", "HTTP URL and method do not match an explicit operator grant")
    }
}

public func loadHostPluginHttpConfiguration(settingsRoot: String, namespace: String, packageDigest: String): Result<HostPluginHttpConfiguration> {
    let source = match (readHostPluginHttpConfiguration(settingsRoot)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let document = try { parseUnifiedJson(source, maxBytes: HOST_PLUGIN_HTTP_CONFIGURATION_MAX_BYTES, maxDepth: 32) }
        catch (_: Exception) { return hostPluginHttpConfigError("plugin.http_configuration_invalid", "operator HTTP configuration is not valid bounded JSON") }
    if (!httpIntentExactFields(document, ["version", "plugins"]) ||
        document.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
        document.field("version").getOrThrow().asNumberText() != "1") {
        return hostPluginHttpConfigError("plugin.http_configuration_invalid", "operator HTTP configuration requires version 1 and plugins only")
    }
    let plugins = document.field("plugins").getOrThrow()
    if (plugins.unifiedKind != ValueKind.List || plugins.items.size > 128) {
        return hostPluginHttpConfigError("plugin.http_configuration_invalid", "operator HTTP plugin configuration list is invalid")
    }
    let seen = ArrayList<String>()
    var selected: ?HostPluginHttpConfiguration = None
    for (plugin in plugins.items) {
        if (!hostPluginReadViewConfigurationFields(plugin)) {
            return hostPluginHttpConfigError("plugin.http_configuration_invalid", "operator HTTP plugin configuration contains unknown, missing, or repeated fields")
        }
        let name = httpIntentText(plugin, "namespace")
        let packageHash = httpIntentText(plugin, "package_digest")
        if (!hostPluginHttpNamespace(name) || !hostPluginHttpPackageDigest(packageHash) || seen.contains(name) ||
            plugin.field("configuration").getOrThrow().unifiedKind != ValueKind.Object) {
            return hostPluginHttpConfigError("plugin.http_configuration_invalid", "operator HTTP plugin identity or nonsecret configuration is invalid")
        }
        seen.add(name)
        let protocolLimits = match (serviceProtocolLimits(plugin)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let payloadLimits = match (servicePayloadLimits(plugin)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let readOnlyTools: Array<String> = match (plugin.field("read_only_tools")) {
            case Some(value) => match (parseServiceReadOnlyTools(value)) {
                case Result.Ok(tools) => tools; case Result.Err(error) => return Result.Err(error)
            }
            case None => []
        }
        let ordinaryReadTools: Array<String> = match (plugin.field("tool_read_grants")) {
            case Some(value) => match (parseOrdinaryToolReadGrants(value)) {
                case Result.Ok(names) => names; case Result.Err(error) => return Result.Err(error)
            }
            case None => []
        }
        let parameterReferences: Array<String> = match (plugin.field("read_view_parameter_references")) {
            case Some(value) => match (parseServiceReadOnlyTools(value)) {
                case Result.Ok(names) => names; case Result.Err(error) => return Result.Err(error) }
            case None => []
        }
        let parameterContexts: Array<String> = match (plugin.field("read_view_parameter_contexts")) {
            case Some(value) => match (parseServiceReadOnlyTools(value)) {
                case Result.Ok(names) => names; case Result.Err(error) => return Result.Err(error) }
            case None => [] }
        for (name in parameterContexts where !parameterReferences.contains(name) || !ordinaryReadTools.contains(name)) {
            return hostPluginHttpConfigError("read_view.parameter_context_ungranted", "context metadata requires this exact ordinary read and parameter-reference grant") }
        let credentials = match (parseHostPluginHttpCredentials(plugin.field("credentials").getOrThrow())) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let requests = match (parseHostPluginHttpRequests(plugin.field("requests").getOrThrow(), credentials)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (name == namespace && packageHash == packageDigest) {
            selected = Some(HostPluginHttpConfiguration(settingsRoot, name, packageHash,
                plugin.field("configuration").getOrThrow(), modelPolicySha256Text(source), requests, credentials, readOnlyTools: readOnlyTools, protocolLimits: protocolLimits, ordinaryReadTools: ordinaryReadTools, payloadLimits: payloadLimits, readonlyDelegations: match (plugin.field("tool_delegations")) { case Some(value) => value; case None => listValue([]) },
                toolPayloadLimits: plugin.field("tool_payload_limits") ?? listValue([]), readViewParameterReferences: parameterReferences,
                toolInputAttachments: plugin.field("tool_input_attachments") ?? listValue([]),
                readViewDeadlines: plugin.field("read_view_deadlines") ?? listValue([]), readViewParameterContexts: parameterContexts))
        }
    }
    match (selected) {
        case Some(value) => Result.Ok(value)
        case None => hostPluginHttpConfigError("plugin.http_configuration_missing", "no operator HTTP configuration matches this plugin namespace and package digest")
    }
}

public func parseHostPluginHttpCredentials(value: AgentValue): Result<Array<HostPluginHttpCredentialBinding>> {
    if (value.unifiedKind != ValueKind.List || value.items.size > 32) {
        return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP credential bindings must be a bounded list")
    }
    let result = ArrayList<HostPluginHttpCredentialBinding>()
    let seen = ArrayList<String>()
    for (binding in value.items) {
        let ref = httpIntentText(binding, "ref")
        if (!httpIntentExactFields(binding, ["ref", "source", "injection"]) || !httpIntentIdentifier(ref) || seen.contains(ref)) {
            return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP credential binding identity is invalid")
        }
        seen.add(ref)
        let source = binding.field("source").getOrThrow()
        let environment = httpIntentText(source, "environment")
        let file = httpIntentText(source, "file")
        if (!(httpIntentExactFields(source, ["environment"]) && hostPluginHttpEnvironmentName(environment)) &&
            !(httpIntentExactFields(source, ["file"]) && hostPluginHttpRelativePath(file))) {
            return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP credential source must be one explicit environment name or relative credential file")
        }
        let injection = binding.field("injection").getOrThrow()
        let header = httpIntentText(injection, "header").toAsciiLower()
        let pointer = httpIntentText(injection, "json_pointer")
        var field = ""
        var prefix = ""
        if ((httpIntentExactFields(injection, ["header"]) || httpIntentExactFields(injection, ["header", "prefix"])) &&
            (header == "authorization" || httpServiceHeaderAllowed(header))) {
            match (injection.field("prefix")) {
                case Some(value) =>
                    if (value.unifiedKind != ValueKind.Text || !hostPluginHttpHeaderPrefixValid(value.text)) {
                        return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP credential header prefix is invalid")
                    }
                    prefix = value.text
                case None => ()
            }
        } else if (httpIntentExactFields(injection, ["json_pointer"])) {
            field = match (hostPluginHttpJsonPointerField(pointer)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        } else {
            return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP credential injection location is invalid or host-controlled")
        }
        result.add(HostPluginHttpCredentialBinding(ref, environment, file, header, pointer, field, headerPrefix: prefix))
    }
    Result.Ok(result.toArray())
}

// Public, nonsecret formatting only; no template expansion or second source.
public func hostPluginHttpHeaderPrefixValid(value: String): Bool {
    if (value.size > 128) { return false }
    for (byte in value.toArray() where byte < 32u8 || byte > 126u8) { return false }
    true
}

public func parseHostPluginHttpRequests(value: AgentValue, credentials: Array<HostPluginHttpCredentialBinding>): Result<Array<HostPluginHttpRequestGrant>> {
    if (value.unifiedKind != ValueKind.List || value.items.size > 32) {
        return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP request grants must be a bounded list")
    }
    let result = ArrayList<HostPluginHttpRequestGrant>()
    let seen = ArrayList<String>()
    for (request in value.items) {
        if (!httpIntentExactFields(request, ["url", "methods", "private_addresses", "credential_refs"])) {
            return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP request grant has unknown, missing, or repeated fields")
        }
        let endpoint = match (httpServiceEndpoint(httpIntentText(request, "url"))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let methods = match (hostPluginHttpStringList(request.field("methods").getOrThrow(), 2)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (methods.isEmpty()) { return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP request grant requires a method") }
        for (method in methods) {
            let key = method + " " + endpoint.url
            if ((method != "GET" && method != "POST") || seen.contains(key)) {
                return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP grant methods are unsupported or overlap")
            }
            seen.add(key)
        }
        let addresses = match (hostPluginHttpStringList(request.field("private_addresses").getOrThrow(), 16)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let refs = match (hostPluginHttpStringList(request.field("credential_refs").getOrThrow(), 4)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (ref in refs) {
            var found = false
            for (binding in credentials where binding.ref == ref) { found = true }
            if (!found) { return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP grant names an unknown credential reference") }
        }
        let network = try { NetworkPolicy(NetworkPolicyMode.Mediated,
            egress: [NetworkEgressRule(endpoint.host, endpoint.port, privateAddresses: addresses)]) }
            catch (_: Exception) { return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP grant has invalid origin or private-address constraints") }
        result.add(HostPluginHttpRequestGrant(endpoint.url, methods, refs, network))
    }
    Result.Ok(result.toArray())
}

public func hostPluginHttpStringList(value: AgentValue, maximum: Int64): Result<Array<String>> {
    if (value.unifiedKind != ValueKind.List || value.items.size > maximum) {
        return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP configuration list is invalid or oversized")
    }
    let result = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != ValueKind.Text || item.text == "" || result.contains(item.text)) {
            return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP configuration list entries must be unique nonempty strings")
        }
        result.add(item.text)
    }
    Result.Ok(result.toArray())
}

public func hostPluginHttpJsonPointerField(pointer: String): Result<String> {
    if (pointer.size < 2 || pointer.size > 256 || !pointer.startsWith("/") || pointer[1..].contains("/") ||
        pointer.contains("\u{0000}") || pointer.contains("\r") || pointer.contains("\n")) {
        return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP JSON credential pointer must select one nonempty top-level field")
    }
    let token = pointer[1..]
    var index: Int64 = 0
    while (index < token.size) {
        if (token[index] == 126u8) {
            if (index + 1 >= token.size || (token[index + 1] != 48u8 && token[index + 1] != 49u8)) {
                return hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP JSON credential pointer has an invalid escape")
            }
            index += 1
        }
        index += 1
    }
    Result.Ok(token.replace("~1", "/").replace("~0", "~"))
}

public func hostPluginHttpNamespace(value: String): Bool {
    if (value == "" || value.size > 256) { return false }
    for (byte in value.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
        (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) ||
        byte == 45u8 || byte == 46u8 || byte == 58u8 || byte == 95u8)) { return false }
    true
}

public func hostPluginHttpPackageDigest(value: String): Bool {
    // Match the package loader's canonical identity verbatim. Configuration
    // file digests are a separate, unprefixed SHA-256 of their complete bytes.
    if (value.size != 71 || !value.startsWith("sha256:")) { return false }
    for (byte in value[7..].toArray() where !((byte >= 48u8 && byte <= 57u8) || (byte >= 97u8 && byte <= 102u8))) { return false }
    true
}

public func hostPluginHttpEnvironmentName(value: String): Bool {
    if (value == "" || value.size > 256 || (value[0] >= 48u8 && value[0] <= 57u8)) { return false }
    for (byte in value.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
        (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) || byte == 95u8)) { return false }
    true
}

public func hostPluginHttpRelativePath(value: String): Bool {
    if (value == "" || value.size > 1024 || value.startsWith("/") || value.contains("\\") || value.contains(":")) { return false }
    for (byte in value.toArray() where byte < 32u8 || byte == 127u8) { return false }
    for (part in value.split("/")) { if (part == "" || part == "." || part == "..") { return false } }
    true
}

public func hostPluginHttpCredentialFile(settingsRoot: String, relative: String): Result<String> {
    if (!hostPluginHttpRelativePath(relative)) {
        return hostPluginHttpConfigError("plugin.http_credential_path_invalid", "HTTP credential file must remain under the settings credential directory")
    }
    hostPluginHttpSafeFile(settingsRoot, "credentials/" + relative, "plugin.http_credential_path_invalid")
}

public func hostPluginHttpSafeFile(settingsRoot: String, relative: String, code: String): Result<String> {
    try {
        let root = canonicalize(Path(settingsRoot)).toString()
        var path = Path(root)
        for (part in relative.split("/")) {
            path = path.join(part)
            if (FileInfo(path).isSymbolicLink()) { return hostPluginHttpConfigError(code, "HTTP configuration and credential paths may not traverse symbolic links") }
        }
        let actual = canonicalize(path).toString()
        if (!actual.startsWith(root + "/") || !FileInfo(path).isRegular()) {
            return hostPluginHttpConfigError(code, "HTTP configuration or credential path is not a regular file inside settings")
        }
        Result.Ok(actual)
    } catch (_: Exception) { hostPluginHttpConfigError(code, "HTTP configuration or credential file is unavailable") }
}

public func readHostPluginHttpConfiguration(settingsRoot: String): Result<String> {
    if (!exists(Path(settingsRoot).join("plugins/services.json"))) {
        return hostPluginHttpConfigError("plugin.http_configuration_missing", "operator HTTP configuration is not configured")
    }
    let path = match (hostPluginHttpSafeFile(settingsRoot, "plugins/services.json", "plugin.http_configuration_invalid")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    readHostPluginHttpBoundedText(path, HOST_PLUGIN_HTTP_CONFIGURATION_MAX_BYTES)
}

public func readHostPluginHttpBoundedText(path: String, maximum: Int64): Result<String> {
    try {
        if (FileInfo(path).size > maximum) { return hostPluginHttpConfigError("plugin.http_configuration_limit", "HTTP configuration or credential file exceeds its byte limit") }
        let file = File(path, OpenMode.Read)
        try {
            let bytes = ArrayList<Byte>()
            let buffer = Array<Byte>(4096, repeat: 0)
            while (true) {
                let count = file.read(buffer)
                if (count <= 0) { break }
                if (bytes.size + count > maximum) { return hostPluginHttpConfigError("plugin.http_configuration_limit", "HTTP configuration or credential file exceeds its byte limit") }
                for (index in 0..count) { bytes.add(buffer[index]) }
            }
            Result.Ok(String.fromUtf8(bytes.toArray()))
        } finally { file.close() }
    } catch (_: Exception) { hostPluginHttpConfigError("plugin.http_configuration_invalid", "HTTP configuration or credential file cannot be read as bounded UTF-8") }
}

public func hostPluginHttpConfigError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code, message))
}

// Ordinary Tool grants share the operator file, not the dynamic Service
// read_only_tools namespace or its startup authority. Reject duplicate fields.
public func hostPluginReadViewConfigurationFields(value: AgentValue): Bool {
    let fields = ArrayList<ValueField>(); var count: Int64 = 0; var delegationCount: Int64 = 0; var payloadCount: Int64 = 0; var referenceCount: Int64 = 0; var attachmentCount: Int64 = 0; var deadlineCount: Int64 = 0; var contextCount: Int64 = 0
    for (field in value.fields) {
        if (field.name == "tool_read_grants") { count++; if (parseOrdinaryToolReadGrants(field.value).isError()) { return false } }
        else if (field.name == "tool_delegations") { delegationCount++; if (!hostValidReadonlyDelegationGrants(field.value)) { return false } }
        else if (field.name == "tool_payload_limits") { payloadCount++; if (!validOrdinaryToolPayloadGrants(field.value)) { return false } }
        else if (field.name == "tool_input_attachments") { attachmentCount++; if (!validToolInputAttachmentGrants(field.value)) { return false } }
        else if (field.name == "read_view_deadlines") { deadlineCount++; if (!validReadViewDeadlineGrants(field.value)) { return false } }
        else if (field.name == "read_view_parameter_contexts") { contextCount++; if (parseServiceReadOnlyTools(field.value).isError()) { return false } }
        else if (field.name == "read_view_parameter_references") { referenceCount++; if (parseServiceReadOnlyTools(field.value).isError()) { return false } }
        else { fields.add(ValueField(field.name, field.value)) }
    }
    count <= 1 && delegationCount <= 1 && payloadCount <= 1 && referenceCount <= 1 && attachmentCount <= 1 && deadlineCount <= 1 && contextCount <= 1 && serviceEffectGrantFields(objectValue(fields.toArray()),
        ["namespace", "package_digest", "configuration", "requests", "credentials"])
}
