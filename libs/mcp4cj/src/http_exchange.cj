package mcp4cj

import std.io.*
import std.sync.*
import stdx.log.NoopLogger
import stdx.net.http.*
import stdx.net.tls.*

// Generic HTTP bytes only. The library owns protocol headers and framing.
// An injected broker port must obtain authority separately and clamp these
// requested timeouts to its host-owned lease/deadline.
public class McpHttpExchangeRequest {
    public let url: String
    public let method: String
    public let body: String
    public let readTimeoutMillis: ?Int64
    public let writeTimeoutMillis: Int64
    private let headerValues: Array<McpHttpHeader>
    public prop headers: Array<McpHttpHeader> { get() { headerValues.clone() } }

    public init(url: String, headers: Array<McpHttpHeader>, body: String,
        readTimeoutMillis: ?Int64, writeTimeoutMillis: Int64) {
        if (!secureMcpHttpUrl(url) || writeTimeoutMillis <= 0) {
            throw IllegalArgumentException("invalid MCP HTTP exchange request")
        }
        match (readTimeoutMillis) {
            case Some(value) => if (value <= 0) { throw IllegalArgumentException("invalid HTTP read timeout") }
            case None => ()
        }
        this.url = url
        this.method = "POST"
        this.headerValues = headers.clone()
        this.body = body
        this.readTimeoutMillis = readTimeoutMillis
        this.writeTimeoutMillis = writeTimeoutMillis
    }
}

public interface McpHttpExchangeResponse {
    prop status: Int64
    // Exact metadata whitelist consumed by the existing stateless client.
    // Request protocol/session headers remain part of the request, not this DTO.
    prop contentType: String
    prop bodySize: ?Int64
    prop body: InputStream
    func close(): Unit
}

public interface McpHttpExchange {
    // Exactly one send. close before send must prevent all network effects.
    func send(): McpHttpExchangeResponse
    // Concurrent close interrupts connect/header/body waits; no send/read lock.
    // Late response handles must be closed too. Repetition is harmless.
    func close(): Unit
}

public interface McpHttpExchangePort {
    // Must not perform network I/O. The returned exchange is registered with
    // the transport cancellation owner before send is allowed.
    func prepare(request: McpHttpExchangeRequest): McpHttpExchange
}

// Callback diagnostics can contain broker implementation details or secrets.
// Keep the existing JSON/SSE error codes while translating the client I/O
// boundary. The response owner still closes the underlying stream.
class McpClientResponseInput <: InputStream {
    private let input: InputStream
    init(input: InputStream) { this.input = input }
    public func read(buffer: Array<Byte>): Int64 {
        try { input.read(buffer) }
        catch (_: Exception) { throw IllegalStateException("MCP HTTP response stream failed") }
    }
}

class StdXMcpHttpResponse <: McpHttpExchangeResponse {
    private let response: HttpResponse
    private let lock = Mutex()
    private var closed = false
    init(response: HttpResponse) { this.response = response }
    public prop status: Int64 { get() { Int64(response.status) } }
    public prop contentType: String { get() { response.headers.getFirst("content-type") ?? "" } }
    public prop bodySize: ?Int64 { get() { response.bodySize } }
    public prop body: InputStream { get() { response.body } }
    public func close(): Unit {
        lock.lock()
        try { if (closed) { return }; closed = true } finally { lock.unlock() }
        response.close()
    }
}

class StdXMcpHttpExchange <: McpHttpExchange {
    private let client: Client
    private let request: HttpRequest
    private let lock = Mutex()
    private var started = false
    private var closed = false
    private var response: ?McpHttpExchangeResponse = None
    init(client: Client, request: HttpRequest) { this.client = client; this.request = request }

    public func send(): McpHttpExchangeResponse {
        lock.lock()
        try {
            if (closed || started) { throw IllegalStateException("HTTP exchange is closed or already sent") }
            started = true
        } finally { lock.unlock() }
        // Never hold lock across network I/O; close must be able to interrupt it.
        let received = StdXMcpHttpResponse(client.send(request))
        var wasClosed = false
        lock.lock()
        try {
            wasClosed = closed
            if (!wasClosed) { response = Some(received) }
        } finally { lock.unlock() }
        if (wasClosed) {
            received.close()
            throw IllegalStateException("HTTP exchange closed before response handoff")
        }
        received
    }

    public func close(): Unit {
        var captured: ?McpHttpExchangeResponse = None
        lock.lock()
        try {
            if (closed) { return }
            closed = true
            captured = response
        } finally { lock.unlock() }
        try { match (captured) { case Some(value) => value.close(); case None => () } }
        finally { client.close() }
    }
}

// Compatibility backend only. A plugin must inject a broker implementation;
// this adapter does not claim to be a host capability or a credential vault.
class StdXMcpHttpExchangePort <: McpHttpExchangePort {
    private let proxyUrl: String
    init(proxyUrl: String) { this.proxyUrl = proxyUrl }
    public func prepare(request: McpHttpExchangeRequest): McpHttpExchange {
        let writeTimeout = Duration.millisecond * request.writeTimeoutMillis
        let readTimeout = match (request.readTimeoutMillis) {
            case Some(value) => Duration.millisecond * value
            case None => Duration.Max
        }
        let clientBuilder = ClientBuilder().autoRedirect(false)
            .readTimeout(readTimeout).writeTimeout(writeTimeout).logger(NoopLogger())
        if (proxyUrl == "") {
            clientBuilder.noProxy()
        } else {
            clientBuilder.httpProxy(proxyUrl).httpsProxy(proxyUrl)
        }
        if (request.url.startsWith("https://")) { clientBuilder.tlsConfig(TlsClientConfig()) }
        let client = clientBuilder.build()
        try {
            let builder = HttpRequestBuilder().url(request.url).post()
                .readTimeout(readTimeout).writeTimeout(writeTimeout).body(request.body)
            for (header in request.headers) { builder.header(header.name, header.value) }
            StdXMcpHttpExchange(client, builder.build())
        } catch (error: Exception) {
            try { client.close() } catch (_: Exception) {}
            throw error
        }
    }
}
