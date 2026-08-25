package model_adapters

import agent_domain as domain
import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import stdx.log.NoopLogger
import stdx.net.http.*
import stdx.net.tls.*

private let NATIVE_PROVIDER_BODY_LIMIT: Int64 = 67108864

private class ActiveNativeRequest {
    let requestId: String
    let client: Client
    var response: ?HttpResponse = None
    var cancelled: Bool = false

    init(requestId: String, client: Client) {
        this.requestId = requestId
        this.client = client
    }
}

private class NativeBodyRead {
    let bytes: Array<Byte>
    let emitted: Bool

    init(bytes: Array<Byte>, emitted: Bool) {
        this.bytes = bytes
        this.emitted = emitted
    }
}

// Native stdx HTTP transport.  Each request owns one Client so cancellation
// can close the underlying connection without aborting unrelated model calls.
public class NativeProviderTransport <: ProviderTransport {
    private let active = ArrayList<ActiveNativeRequest>()
    private let activeLock = Mutex()
    private let credentials: ProviderCredentialResolver

    public init(credentials!: ProviderCredentialResolver = EnvironmentFileCredentialResolver()) {
        this.credentials = credentials
    }

    public func post(
        provider: ProviderSpec,
        payload: String,
        streaming: Bool,
        requestId: String,
        chunks: (String) -> Unit
    ): domain.Result<String> {
        if (!secureNativeProviderUrl(provider.baseUrl)) {
            return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Configuration,
                "model.insecure_provider_url",
                "provider base URL must use HTTPS or loopback HTTP",
                fields: [domain.ErrorField("provider_id", provider.id)]
            ))
        }
        let apiKey = match (credentials.resolve(provider, requestId)) {
            case domain.Result.Ok(value) => value
            case domain.Result.Err(error) =>
                credentials.complete(requestId)
                return domain.Result.Err(error)
        }
        if (apiKey.contains("\n") || apiKey.contains("\r")) {
            credentials.complete(requestId)
            return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Configuration,
                "model.invalid_api_key",
                "provider API key contains unsafe header characters",
                fields: [domain.ErrorField("environment", provider.apiKeyEnv)]
            ))
        }
        let timeout = Duration.millisecond * provider.timeoutMillis
        let client = nativeProviderClient(provider.baseUrl, provider.timeoutMillis)
        match (registerNative(requestId, client)) {
            case domain.Result.Err(error) =>
                try { client.close() } catch (_: Exception) {}
                credentials.complete(requestId)
                return domain.Result.Err(error)
            case domain.Result.Ok(_) => ()
        }
        let startedAt = MonoTime.now()
        var emitted = false
        try {
            let builder = HttpRequestBuilder()
                .url(provider.endpoint())
                .post()
                .body(payload)
            for (header in effectiveProviderHeaders(provider, streaming)) {
                builder.header(header.name, header.value)
            }
            if (provider.timeoutMillis > 0) {
                builder.readTimeout(timeout).writeTimeout(timeout)
            } else {
                // ClientBuilder defaults response reads to 15 seconds. Core
                // streaming requests use zero to delegate liveness entirely
                // to the semantic-progress idle watchdog, so zero must be
                // lowered to an explicit unlimited request read timeout.
                builder.readTimeout(Duration.Max)
            }
            match (provider.protocol) {
                case ProviderProtocol.Messages =>
                    builder.header("x-api-key", apiKey)
                case ProviderProtocol.Responses | ProviderProtocol.Completions =>
                    builder.header("authorization", "Bearer " + apiKey)
            }
            let response = client.send(builder.build())
            attachNativeResponse(requestId, response)
            if (nativeCancelled(requestId)) {
                return cancelledNative(requestId)
            }
            let read = readNativeBody(response.body, streaming, { chunk =>
                chunks(redactNativeProviderText(chunk, apiKey))
            })
            emitted = read.emitted
            if (nativeCancelled(requestId)) {
                return cancelledNative(requestId)
            }
            let body = redactNativeProviderText(
                String.fromUtf8(read.bytes),
                apiKey
            )
            let elapsedMillis = (MonoTime.now() - startedAt).toMilliseconds()
            // ProviderSpec.timeoutMillis is the whole-request limit (the curl
            // transport maps it to --max-time), not merely an idle-read hint.
            // stdx HTTP may surface an expired read by ending the body without
            // throwing, including after one or more partial SSE frames. Once
            // the request limit has elapsed, timeout is therefore authoritative
            // over a later missing-terminal wire diagnosis.
            if (provider.timeoutMillis > 0 && elapsedMillis >= provider.timeoutMillis) {
                return domain.Result.Err(domain.AgentError(
                    domain.AgentErrorKind.Timeout,
                    "model.timeout",
                    "provider response timed out before a terminal event",
                    retryable: !emitted,
                    fallbackAllowed: !emitted,
                    fields: [
                        domain.ErrorField("provider_id", provider.id),
                        domain.ErrorField("elapsed_ms", elapsedMillis.toString())
                    ]
                ))
            }
            let status = Int64(response.status)
            if (status < 200 || status >= 300) {
                let retryAfter = match (response.headers.getFirst("retry-after")) {
                    case Some(value) => extractRetryAfterHeader("retry-after: " + value + "\n")
                    case None => 0
                }
                return domain.Result.Err(providerFailure(
                    22,
                    status,
                    body.trimAscii(),
                    provider.id,
                    retryAfterMillis: retryAfter
                ))
            }
            domain.Result.Ok(body)
        } catch (error: Exception) {
            if (nativeCancelled(requestId)) {
                cancelledNative(requestId)
            } else {
                let message = redactNativeProviderText(error.message, apiKey)
                let elapsedMillis = (MonoTime.now() - startedAt).toMilliseconds()
                if (provider.timeoutMillis > 0 && elapsedMillis >= provider.timeoutMillis) {
                    domain.Result.Err(domain.AgentError(
                        domain.AgentErrorKind.Timeout,
                        "model.timeout",
                        message,
                        retryable: !emitted,
                        fallbackAllowed: !emitted,
                        fields: [
                            domain.ErrorField("provider_id", provider.id),
                            domain.ErrorField("elapsed_ms", elapsedMillis.toString())
                        ]
                    ))
                } else {
                    domain.Result.Err(domain.AgentError(
                        domain.AgentErrorKind.Transport,
                        if (streaming && emitted) {
                            "model.streaming_interrupted"
                        } else {
                            "model.transport_internal"
                        },
                        message,
                        retryable: !emitted,
                        fallbackAllowed: !emitted,
                        fields: [
                            domain.ErrorField("provider_id", provider.id),
                            domain.ErrorField("partial_stream", emitted.toString())
                        ]
                    ))
                }
            }
        } finally {
            credentials.complete(requestId)
            let item = finishNative(requestId)
            match (item) {
                case Some(value) =>
                    match (value.response) {
                        case Some(response) => try { response.close() } catch (_: Exception) {}
                        case None => ()
                    }
                    try { value.client.close() } catch (_: Exception) {}
                case None => try { client.close() } catch (_: Exception) {}
            }
        }
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        let credentialCancellation = credentials.cancel(requestId)
        activeLock.lock()
        try {
            for (item in active where item.requestId == requestId) {
                item.cancelled = true
                match (item.response) {
                    case Some(response) => try { response.close() } catch (_: Exception) {}
                    case None => ()
                }
                try { item.client.close() } catch (_: Exception) {}
                return domain.Result.Ok(())
            }
            credentialCancellation
        } finally {
            activeLock.unlock()
        }
    }

    private func registerNative(
        requestId: String,
        client: Client
    ): domain.Result<Unit> {
        activeLock.lock()
        try {
            for (item in active where item.requestId == requestId) {
                return domain.Result.Err(domain.AgentError(
                    domain.AgentErrorKind.InvalidInput,
                    "model.duplicate_request_id",
                    "a provider request with this request id is already active",
                    fields: [domain.ErrorField("request_id", requestId)]
                ))
            }
            active.add(ActiveNativeRequest(requestId, client))
            domain.Result.Ok(())
        } finally {
            activeLock.unlock()
        }
    }

    private func attachNativeResponse(requestId: String, response: HttpResponse): Unit {
        activeLock.lock()
        try {
            for (item in active where item.requestId == requestId) {
                item.response = Some(response)
                if (item.cancelled) {
                    try { response.close() } catch (_: Exception) {}
                }
                return
            }
            try { response.close() } catch (_: Exception) {}
        } finally {
            activeLock.unlock()
        }
    }

    private func nativeCancelled(requestId: String): Bool {
        activeLock.lock()
        try {
            for (item in active where item.requestId == requestId) {
                return item.cancelled
            }
            false
        } finally {
            activeLock.unlock()
        }
    }

    private func finishNative(requestId: String): ?ActiveNativeRequest {
        activeLock.lock()
        try {
            for (index in 0..active.size) {
                if (active[index].requestId == requestId) {
                    let value = active[index]
                    active.remove(at: index)
                    return Some(value)
                }
            }
            None
        } finally {
            activeLock.unlock()
        }
    }
}

// stdx HTTP deliberately has no implicit TLS configuration.  Bind the default
// TLS client configuration only for HTTPS; its default verification mode uses
// the system trust store and keeps certificate and host verification enabled.
func nativeProviderClient(baseUrl: String, timeoutMillis: Int64): Client {
    let builder = ClientBuilder()
        .autoRedirect(false)
        .logger(NoopLogger())
    if (timeoutMillis > 0) {
        let timeout = Duration.millisecond * timeoutMillis
        builder.readTimeout(timeout).writeTimeout(timeout)
    } else {
        // Omitting readTimeout would restore stdx HTTP's 15-second client
        // default, which is not the zero/no-hard-timeout contract.
        builder.readTimeout(Duration.Max)
    }
    if (nativeProviderRequiresTls(baseUrl)) {
        builder.tlsConfig(TlsClientConfig())
    }
    builder.build()
}

func nativeProviderRequiresTls(value: String): Bool {
    value.startsWith("https://")
}

private func secureNativeProviderUrl(value: String): Bool {
    if (value.startsWith("https://")) {
        let authority = nativeProviderUrlAuthority(value, "https://")
        return authority != "" && authority.trimAscii() == authority &&
            authority.indexOf("@").isNone()
    }
    if (!value.startsWith("http://")) { return false }
    nativeProviderLoopbackAuthority(
        nativeProviderUrlAuthority(value, "http://")
    )
}

private func nativeProviderUrlAuthority(value: String, prefix: String): String {
    let remainder = value[prefix.size..]
    var end = remainder.size
    for (separator in ["/", "?", "#"]) {
        match (remainder.indexOf(separator)) {
            case Some(index) => end = min(end, index)
            case None => ()
        }
    }
    remainder[..end]
}

private func nativeProviderLoopbackAuthority(authority: String): Bool {
    if (authority == "127.0.0.1" || authority == "localhost" || authority == "[::1]") {
        return true
    }
    for (host in ["127.0.0.1", "localhost", "[::1]"]) {
        let prefix = host + ":"
        if (authority.startsWith(prefix) &&
            nativeProviderAsciiDecimal(authority[prefix.size..])) {
            return true
        }
    }
    false
}

private func nativeProviderAsciiDecimal(value: String): Bool {
    if (value == "") { return false }
    for (byte in unsafe { value.rawData() }) {
        if (byte < b'0' || byte > b'9') { return false }
    }
    true
}

private func redactNativeProviderText(value: String, apiKey: String): String {
    if (apiKey == "") { value } else { value.replace(apiKey, "[REDACTED]") }
}

private func readNativeBody(
    stream: InputStream,
    streaming: Bool,
    chunks: (String) -> Unit
): NativeBodyRead {
    let output = ArrayList<Byte>()
    let line = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    var emitted = false
    while (true) {
        let count = stream.read(buffer)
        if (count <= 0) {
            break
        }
        if (Int64(output.size) + count > NATIVE_PROVIDER_BODY_LIMIT) {
            throw IllegalStateException("provider response exceeds 64 MiB")
        }
        for (index in 0..count) {
            let byte = buffer[index]
            output.add(byte)
            if (streaming) {
                line.add(byte)
                if (byte == b'\n') {
                    chunks(String.fromUtf8(line.toArray()))
                    line.clear()
                    emitted = true
                }
            }
        }
    }
    if (streaming && !line.isEmpty()) {
        chunks(String.fromUtf8(line.toArray()))
        emitted = true
    }
    NativeBodyRead(output.toArray(), emitted)
}

private func cancelledNative<T>(requestId: String): domain.Result<T> {
    domain.Result.Err(domain.AgentError(
        domain.AgentErrorKind.Cancelled,
        "model.cancelled",
        "model request was cancelled",
        fields: [domain.ErrorField("request_id", requestId)]
    ))
}
