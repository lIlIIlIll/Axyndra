package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

public func hostRegisterPluginHttpService(catalog: ToolCatalog, host: HostJavaScriptPluginHost,
    operations: OperationRuntimePort, settingsRoot: String, caBundle: String): Result<Unit> {
    catalog.register(ToolDescriptor(
        ModelToolDefinition(HOST_HTTP_SERVICE_TOOL, "Execute one exactly prepared HTTP intent through the host gateway.",
            hostObjectSchema([
                hostSchemaProperty("plugin", "string"), hostSchemaProperty("generation", "string"),
                hostSchemaProperty("package_digest", "string"), hostSchemaProperty("configuration_digest", "string"),
                hostSchemaProperty("intent", "object")
            ], ["plugin", "generation", "package_digest", "configuration_digest", "intent"])),
        Capability(CapabilityKind.NetworkAccess), hostServiceOnly: true, neverReplay: true,
        implementationVersion: "host-http-intent-v1", implementationFingerprint: "host-http-intent-v1",
        capabilityResolver: Some({ call => Capability(CapabilityKind.NetworkAccess,
            resource: match (hostPluginHttpChildPolicy(call)) {
                case Result.Ok(policy) => networkEgressResource(policy.egress[0])
                case Result.Err(_) => "invalid-http-intent"
            }) }),
        sideEffectResolver: Some({ call => match (call.arguments.field("intent")) {
            case Some(intent) => match (intent.field("request")) {
                case Some(request) => httpIntentText(request, "method") != "GET"
                case None => true
            }
            case None => true
        } }),
        networkPolicyResolver: Some({ call => hostPluginHttpChildPolicy(call) })
    ), HostPluginHttpServiceExecutor(host, operations, settingsRoot, caBundle))
}

func hostPluginHttpChildPolicy(call: ToolCall): Result<NetworkPolicy> {
    match (call.arguments.field("intent")) {
        case Some(intent) => httpIntentPolicy(intent)
        case None => hostPluginResourceError("http.intent_missing", "HTTP child omitted its bound intent")
    }
}

class HostPluginHttpServiceExecutor <: ToolExecutor {
    private let host: HostJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private let settingsRoot: String
    private let caBundle: String

    init(host: HostJavaScriptPluginHost, operations: OperationRuntimePort, settingsRoot: String, caBundle: String) {
        this.host = host
        this.operations = operations
        this.settingsRoot = settingsRoot
        this.caBundle = caBundle
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            prepared.source.parentOperationId.isNone() || prepared.source.operationRoot.isNone() ||
            !isHttpServiceChildPlan(prepared.operationPlan)) {
            return hostPluginResourceError("http.source_invalid", "HTTP requires an admitted, exactly prepared plugin child")
        }
        let parent = match (operations.loadPlan(prepared.source.parentOperationId.getOrThrow(), context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!httpServiceChildAllowed(parent, prepared.operationPlan)) {
            return hostPluginResourceError("http.intent_changed", "HTTP child differs from the approved parent intent")
        }
        let args = prepared.operationPlan.canonicalArguments
        let namespace = httpIntentText(args, "plugin")
        let generation = try { UInt64.parse(httpIntentText(args, "generation")) } catch (_: Exception) { 0u64 }
        let descriptor = match (host.servicePackageData81(namespace, generation)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!descriptor.requestedCapabilities.contains("network.http") ||
            descriptor.contentDigest != httpIntentText(args, "package_digest")) {
            return hostPluginResourceError("http.package_changed", "HTTP package binding is no longer current")
        }
        let packageMatches = match (host.registryPackageMatches81(descriptor.root, namespace: Some(namespace),
            digest: Some(descriptor.contentDigest))) {
            case Result.Err(_) => return hostPluginResourceError("plugin.snapshot_stale", "HTTP plugin package is unavailable")
            case Result.Ok(value) => value }
        if (!packageMatches) {
            return hostPluginResourceError("plugin.snapshot_stale", "HTTP plugin package bytes have changed")
        }
        let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (configuration.digest != httpIntentText(args, "configuration_digest")) {
            return hostPluginResourceError("plugin.http_configuration_changed", "HTTP configuration changed after preparation")
        }
        let intent = args.field("intent").getOrThrow()
        let request = intent.field("request").getOrThrow()
        // Rebind the frozen request against the current operator grants before
        // resolving any secret. The package cannot choose an injection target.
        match (configuration.bindIntents(objectValue([ValueField("intents", listValue([
            objectValue([ValueField("id", intent.field("id").getOrThrow()), ValueField("request", request)])
        ]))]))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(values) => if (values.size != 1 || canonicalAgentValue(values[0]) != canonicalAgentValue(intent)) {
                return hostPluginResourceError("http.grant_changed", "HTTP intent no longer matches the operator grant")
            }
        }
        let cancellation = CancellationSource(parent: Some(context.cancellation))
        let registration = match (host.observeServiceRevocation(namespace, generation, { => let _ = cancellation.cancel() })) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                cancellation.close()
                return Result.Err(error)
        }
        let processes = HostLocalProcessPort(HostLocalReadTargetInspector(descriptor.root), sandboxEnabled: true,
            sandboxCaBundle: caBundle, networkGateway: Some(HostLocalNetworkGatewayPort()),
            registryAdmission: Some({ => host.enterRegistryEffect(namespace, generation) }))
        let finished = CancellationSource()
        let watcher = spawn {
            while (!finished.token.isCancelled() && !cancellation.token.isCancelled()) {
                match (configuration.stillCurrent()) {
                    case Result.Err(_) => let _ = cancellation.cancel()
                    case Result.Ok(_) => ()
                }
                sleep(Duration.millisecond * 25)
            }
        }
        try {
            let credentials = match (configuration.resolveCredentials(request)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let argv = match (hostPluginHttpCurlArguments(request, credentials)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let secrets = ArrayList<String>()
            for (credential in credentials) { for (value in credential.redactedValues()) { secrets.add(value) } }
            var timeout = Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText())
            if (context.cancellation.deadlineMillis > 0) {
                let remaining = context.cancellation.deadlineMillis - agentUtcMillis()
                if (remaining < 1) { return Result.Err(AgentError(AgentErrorKind.Cancelled, "http.cancelled", "HTTP deadline elapsed before launch")) }
                if (remaining < timeout) { timeout = remaining }
            }
            let boundedTimeout = timeout
            let scoped = hostPluginProcessCancellationContext(context, cancellation.token)
            let result = match (hostProcessOperations(processes, "plugin-http").execute(scoped, prepared, { _ =>
                processes.execute(ProcessRequest("/usr/bin/curl", operationId: prepared.operationId,
                    arguments: argv, workingDirectory: descriptor.root, timeoutMillis: boundedTimeout,
                    sandboxMode: ProcessSandboxMode.IsolatedReadOnly, filesystemRoot: descriptor.root,
                    networkPolicy: Some(prepared.operationPlan.networkPolicy), redactedValues: secrets.toArray(),
                    processLimits: hostPluginHttpProcessLimits(context.budget.processLimits)))
            })) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    // Process diagnostics can contain argv or echoed response
                    // text. Only a host-authored code/message leaves this port.
                    if (cancellation.token.isCancelled()) {
                        return Result.Err(AgentError(AgentErrorKind.Cancelled, "http.cancelled", "HTTP exchange was cancelled; it is not retried"))
                    }
                    let _ = error
                    return hostPluginHttpUnknown("HTTP exchange did not produce a verifiable response; it is not retried")
            }
            if (result.exitCode != 0 || result.timedOut || result.truncated) {
                return hostPluginHttpUnknown("HTTP exchange failed, timed out, or exceeded its output limit; it is not retried")
            }
            let split = match (result.stdout.lastIndexOf("\n")) {
                case Some(value) => value
                case None => return hostPluginHttpUnknown("HTTP transport omitted its terminal status")
            }
            let statusText = result.stdout[split + 1..]
            let status = try { Int64.parse(statusText) } catch (_: Exception) { 0 }
            if (statusText.size != 3 || status < 100 || status > 599) {
                return hostPluginHttpUnknown("HTTP transport returned an invalid terminal status")
            }
            let body = result.stdout[..split]
            if (body.size > HOST_HTTP_RESPONSE_MAX_BYTES || hostPluginHttpContainsCredential(body, secrets.toArray())) {
                return hostPluginHttpUnknown("HTTP response was withheld by the host output boundary")
            }
            match (configuration.stillCurrent()) {
                case Result.Err(_) => return hostPluginHttpUnknown("HTTP configuration changed while the exchange was active")
                case Result.Ok(_) => ()
            }
            match (cancellation.token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            // A received 4xx/5xx is a completed HTTP exchange. The business
            // plugin decides how to render it; credentials and headers never
            // enter IPC, the child Receipt, audit metadata or the root result.
            let output = objectValue([
                ValueField("status", integerValue(status)), ValueField("body", textValue(body))
            ])
            if (stringifyUnifiedJson(output).size > 196608) {
                return hostPluginHttpUnknown("HTTP response exceeds the serialized host-service frame limit")
            }
            Result.Ok(ToolResult(prepared.call.callId, output))
        } finally {
            let _ = finished.cancel()
            watcher.get()
            let _ = processes.close()
            registration.dispose()
            cancellation.close()
            finished.close()
        }
    }
}

public func hostPluginHttpCurlArguments(request: AgentValue, credentials: Array<HostPluginHttpCredentialValue>): Result<Array<String>> {
    let args = ArrayList<String>(["-q", "--silent", "--show-error", "--globoff", "--path-as-is",
        "--proto", "=http,https", "--proto-redir", "=http,https", "--max-redirs", "0",
        "--connect-timeout", "10", "--max-filesize", HOST_HTTP_RESPONSE_MAX_BYTES.toString(),
        "--write-out", "\n%{http_code}", "--request", httpIntentText(request, "method")])
    var url = httpIntentText(request, "url")
    var separator = "?"
    for (field in request.field("query").getOrThrow().fields) {
        url += separator + hostPluginHttpPercentEncode(field.name) + "=" + hostPluginHttpPercentEncode(field.value.text)
        separator = "&"
    }
    if (url.size > 16384) { return hostPluginResourceError("http.url_limit", "encoded HTTP URL exceeds 16 KiB") }
    args.add("--url")
    args.add(url)
    let headers = request.field("headers").getOrThrow()
    for (field in headers.fields) {
        args.add("--header")
        args.add(field.name + ": " + field.value.text)
    }
    let body = request.field("json_body").getOrThrow()
    let bodyFields = ArrayList<ValueField>()
    if (body.unifiedKind == ValueKind.Object) { for (field in body.fields) { bodyFields.add(field) } }
    let injectedHeaders = ArrayList<String>()
    for (credential in credentials) {
        if (credential.header != "") {
            for (field in headers.fields where field.name.toAsciiLower() == credential.header.toAsciiLower()) {
                return hostPluginResourceError("http.credential_collision", "credential header is already present in the request")
            }
            if (injectedHeaders.contains(credential.header.toAsciiLower())) {
                return hostPluginResourceError("http.credential_collision", "credential header injection targets collide")
            }
            injectedHeaders.add(credential.header.toAsciiLower())
            args.add("--header")
            args.add(credential.header + ": " + credential.headerValue())
        } else {
            // The configuration parser admits one top-level RFC 6901 token.
            let key = credential.jsonPointer[1..].replace("~1", "/").replace("~0", "~")
            if (body.unifiedKind != ValueKind.Object || body.field(key).isSome()) {
                return hostPluginResourceError("http.credential_collision", "credential JSON field is unavailable or already present")
            }
            for (existing in bodyFields where existing.name == key) {
                return hostPluginResourceError("http.credential_collision", "credential injection targets collide")
            }
            bodyFields.add(ValueField(key, textValue(credential.secret)))
        }
    }
    if (httpIntentText(request, "method") == "POST") {
        let encoded = stringifyUnifiedJson(objectValue(bodyFields.toArray()))
        if (encoded.size > HOST_HTTP_REQUEST_MAX_BYTES) {
            return hostPluginResourceError("http.body_limit", "credential-bound HTTP body exceeds 64 KiB")
        }
        args.add("--data-binary")
        args.add(encoded)
    }
    Result.Ok(args.toArray())
}

public func hostPluginHttpPercentEncode(value: String): String {
    let output = ArrayList<UInt8>()
    let hex = "0123456789ABCDEF".toArray()
    for (byte in value.toArray()) {
        if ((byte >= 48u8 && byte <= 57u8) || (byte >= 65u8 && byte <= 90u8) ||
            (byte >= 97u8 && byte <= 122u8) || byte == 45u8 || byte == 46u8 || byte == 95u8 || byte == 126u8) {
            output.add(byte)
        } else {
            output.add(37u8)
            output.add(hex[Int64(byte / 16u8)])
            output.add(hex[Int64(byte % 16u8)])
        }
    }
    String.fromUtf8(output.toArray())
}

func hostPluginHttpContainsCredential(body: String, secrets: Array<String>): Bool {
    if (!secrets.isEmpty() && body.contains("[REDACTED]")) { return true }
    for (secret in secrets) {
        if (secret == "") { return true }
        let encodedJson = stringifyUnifiedJson(textValue(secret))
        let encodedUrl = hostPluginHttpPercentEncode(secret)
        let encoded64 = hostBase64Bytes(secret.toArray())
        if (body.contains(secret) || body.contains(encodedJson[1..encodedJson.size - 1]) ||
            body.contains(encodedUrl) || body.contains(encodedUrl.toAsciiLower()) || body.contains(encoded64)) { return true }
    }
    // Decode JSON escapes too: ASCII/Unicode-escaped echoes must not evade a
    // raw-byte check. Arbitrary encodings by a remote server are not a secret
    // isolation guarantee; the operator must trust the configured recipient.
    let parsed = match (hostJavascriptPluginDecodeValue(body, maxBytes: HOST_HTTP_RESPONSE_MAX_BYTES)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return false
    }
    hostPluginHttpJsonContainsCredential(parsed, secrets)
}

func hostPluginHttpJsonContainsCredential(value: AgentValue, secrets: Array<String>): Bool {
    if (value.unifiedKind == ValueKind.Text) {
        for (secret in secrets where value.text.contains(secret)) { return true }
    }
    if (value.unifiedKind == ValueKind.Object) {
        for (field in value.fields) {
            for (secret in secrets where field.name.contains(secret)) { return true }
            if (hostPluginHttpJsonContainsCredential(field.value, secrets)) { return true }
        }
    }
    if (value.unifiedKind == ValueKind.List) {
        for (item in value.items where hostPluginHttpJsonContainsCredential(item, secrets)) { return true }
    }
    false
}

func hostPluginHttpProcessLimits(requested: ExecutionResourceLimits): ExecutionResourceLimits {
    ExecutionResourceLimits(maxOutputBytes: if (requested.maxOutputBytes > 0 && requested.maxOutputBytes < 73728) {
        requested.maxOutputBytes
    } else { 73728 }, addressSpaceBytes: requested.addressSpaceBytes, fileSizeBytes: requested.fileSizeBytes,
        openFiles: requested.openFiles, processes: requested.processes, cpuSeconds: requested.cpuSeconds)
}

func hostPluginHttpUnknown<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "http.outcome_unknown", message,
        retryable: false, fallbackAllowed: false))
}
