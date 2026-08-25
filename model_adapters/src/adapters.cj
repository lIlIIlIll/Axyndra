package model_adapters

import agent_domain as domain
import agent_ports as ports
import json4cj.*
import llm4cj.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.process.*
import std.sync.*

public enum ProviderProtocol {
    Messages | Responses | Completions
}

public enum ProviderDialect {
    AnthropicMessages
    | DeepSeekMessages
    | OpenAiResponses
    | OpenAiChat
    | DeepSeekChat
    | GenericMessages
    | GenericChat
}

// Non-secret HTTP metadata owned by the provider runtime. Authentication is
// resolved separately and cannot be supplied through configurable headers.
public class ProviderHeader {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        let normalized = name.trimAscii().toAsciiLower()
        if (!validProviderHeaderName(normalized) || value.contains("\r") ||
            value.contains("\n") || value.contains("\"") || value.contains("\\") ||
            restrictedProviderHeader(normalized)) {
            throw IllegalArgumentException("provider default header is invalid or reserved")
        }
        this.name = normalized
        this.value = value.trimAscii()
    }
}

public class ProviderSpec {
    public let id: String
    public let provider: String
    public let protocol: ProviderProtocol
    public let model: String
    public let baseUrl: String
    public let apiKeyEnv: String
    public let credentialFile: String
    public let timeoutMillis: Int64
    public let messagesFastMode: Bool
    public let dialect: ProviderDialect
    public let endpointMaxOutputTokens: ?Int64
    public let capabilities: domain.ModelCapabilities
    public let profileHeaders: Array<ProviderHeader>
    public let modelHeaders: Array<ProviderHeader>

    public init(
        id: String,
        protocol: ProviderProtocol,
        model: String,
        baseUrl: String,
        apiKeyEnv: String,
        credentialFile!: String = "",
        timeoutMillis!: Int64 = 120000,
        provider!: String = "",
        messagesFastMode!: Bool = false,
        dialect!: ?ProviderDialect = None,
        endpointMaxOutputTokens!: ?Int64 = None,
        capabilities!: domain.ModelCapabilities = defaultProviderCapabilities(),
        profileHeaders!: Array<ProviderHeader> = [],
        modelHeaders!: Array<ProviderHeader> = []
    ) {
        if (id.trimAscii() == "") {
            throw IllegalArgumentException("provider id must not be empty")
        }
        if (model.trimAscii() == "") {
            throw IllegalArgumentException("provider model must not be empty")
        }
        if (baseUrl.trimAscii() == "") {
            throw IllegalArgumentException("provider base URL must not be empty")
        }
        if (apiKeyEnv.trimAscii() == "") {
            throw IllegalArgumentException("provider API key environment name must not be empty")
        }
        if (timeoutMillis < 0) {
            throw IllegalArgumentException("provider timeout must not be negative")
        }
        if (match (endpointMaxOutputTokens) {
            case Some(value) => value < 1
            case None => false
        }) {
            throw IllegalArgumentException("provider endpoint output limit must be positive")
        }
        this.id = id
        this.provider = if (provider.trimAscii() == "") { id } else { provider.trimAscii() }
        this.protocol = protocol
        this.model = model
        this.baseUrl = baseUrl.trimAscii().removeSuffix("/")
        this.apiKeyEnv = apiKeyEnv
        this.credentialFile = credentialFile
        this.timeoutMillis = timeoutMillis
        this.messagesFastMode = messagesFastMode
        let normalizedDialect = match (dialect) {
            case Some(value) => value
            case None => match (protocol) {
                case ProviderProtocol.Messages => ProviderDialect.AnthropicMessages
                case ProviderProtocol.Responses => ProviderDialect.OpenAiResponses
                case ProviderProtocol.Completions => ProviderDialect.OpenAiChat
            }
        }
        if (!providerDialectMatchesProtocol(normalizedDialect, protocol)) {
            throw IllegalArgumentException("provider dialect is incompatible with its protocol")
        }
        this.dialect = normalizedDialect
        this.endpointMaxOutputTokens = endpointMaxOutputTokens
        this.capabilities = capabilities
        this.profileHeaders = profileHeaders
        this.modelHeaders = modelHeaders
    }

    public func endpoint(): String {
        match (protocol) {
            case ProviderProtocol.Messages => baseUrl + "/v1/messages"
            case ProviderProtocol.Responses => baseUrl + "/v1/responses"
            case ProviderProtocol.Completions => baseUrl + "/v1/chat/completions"
        }
    }
}

func providerDialectMatchesProtocol(
    dialect: ProviderDialect,
    protocol: ProviderProtocol
): Bool {
    match ((dialect, protocol)) {
        case (ProviderDialect.AnthropicMessages, ProviderProtocol.Messages) |
            (ProviderDialect.DeepSeekMessages, ProviderProtocol.Messages) |
            (ProviderDialect.GenericMessages, ProviderProtocol.Messages) |
            (ProviderDialect.OpenAiResponses, ProviderProtocol.Responses) |
            (ProviderDialect.OpenAiChat, ProviderProtocol.Completions) |
            (ProviderDialect.DeepSeekChat, ProviderProtocol.Completions) |
            (ProviderDialect.GenericChat, ProviderProtocol.Completions) => true
        case _ => false
    }
}

func validProviderHeaderName(value: String): Bool {
    if (value == "") { return false }
    for (character in value.toRuneArray()) {
        if (!((character >= r'a' && character <= r'z') ||
            (character >= r'0' && character <= r'9') || character == r'-')) {
            return false
        }
    }
    true
}

func restrictedProviderHeader(value: String): Bool {
    value == "authorization" || value == "proxy-authorization" ||
        value == "x-api-key" || value == "cookie" || value == "set-cookie" ||
        value == "host" || value == "content-length"
}

func addOrReplaceProviderHeader(
    headers: ArrayList<ProviderHeader>,
    value: ProviderHeader
): Unit {
    for (index in 0..headers.size) {
        if (headers[index].name == value.name) {
            headers.remove(at: index)
            break
        }
    }
    headers.add(value)
}

// Precedence is profile < model < adapter request headers. Auth is appended
// by the transport after this merge and is never configurable.
public func effectiveProviderHeaders(
    provider: ProviderSpec,
    streaming: Bool
): Array<ProviderHeader> {
    let headers = ArrayList<ProviderHeader>()
    for (value in provider.profileHeaders) { addOrReplaceProviderHeader(headers, value) }
    for (value in provider.modelHeaders) { addOrReplaceProviderHeader(headers, value) }
    addOrReplaceProviderHeader(headers, ProviderHeader("content-type", "application/json"))
    addOrReplaceProviderHeader(headers, ProviderHeader(
        "accept", if (streaming) { "text/event-stream" } else { "application/json" }
    ))
    match (provider.protocol) {
        case ProviderProtocol.Messages =>
            addOrReplaceProviderHeader(headers, ProviderHeader("anthropic-version", "2023-06-01"))
            for (header in providerBetaHeaders(provider)) {
                match (header.indexOf(":")) {
                    case Some(separator) => if (separator > 0) {
                        addOrReplaceProviderHeader(headers, ProviderHeader(
                            header[..separator], header[separator + 1..]
                        ))
                    }
                    case None => ()
                }
            }
        case _ => ()
    }
    headers.toArray()
}

public interface ProviderTransport {
    func post(
        provider: ProviderSpec,
        payload: String,
        streaming: Bool,
        requestId: String,
        chunks: (String) -> Unit
    ): domain.Result<String>

    func cancel(requestId: String): domain.Result<Unit> {
        let _ = requestId
        domain.Result.Ok(())
    }
}

// Credential resolution is separately cancellable so a request can be
// stopped before an HTTP client or subprocess exists.
public interface ProviderCredentialResolver {
    func resolve(provider: ProviderSpec, requestId: String): domain.Result<String>
    func cancel(requestId: String): domain.Result<Unit> {
        let _ = requestId
        domain.Result.Ok(())
    }
    func complete(requestId: String): Unit { let _ = requestId }
}

public class EnvironmentFileCredentialResolver <: ProviderCredentialResolver {
    private let cancelled = ArrayList<String>()
    private let lock = Mutex()

    public func resolve(provider: ProviderSpec, requestId: String): domain.Result<String> {
        if (credentialResolutionCancelled(requestId)) {
            return cancelledCredentialResolution(requestId)
        }
        defaultProviderCredential(provider)
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        lock.lock()
        try {
            if (!cancelled.contains(requestId)) { cancelled.add(requestId) }
            domain.Result.Ok(())
        } finally { lock.unlock() }
    }

    public func complete(requestId: String): Unit {
        lock.lock()
        try {
            for (index in 0..cancelled.size) {
                if (cancelled[index] == requestId) {
                    cancelled.remove(at: index)
                    break
                }
            }
        } finally { lock.unlock() }
    }

    private func credentialResolutionCancelled(requestId: String): Bool {
        lock.lock()
        try { cancelled.contains(requestId) } finally { lock.unlock() }
    }
}

func cancelledCredentialResolution(requestId: String): domain.Result<String> {
    domain.Result.Err(domain.AgentError(
        domain.AgentErrorKind.Cancelled,
        "model.cancelled",
        "model request was cancelled during credential resolution",
        fields: [domain.ErrorField("request_id", requestId)]
    ))
}

// Production transport. Credentials are written to a mode-0600 curl config
// file and never appear in the child-process argument list.
public class CurlProviderTransport <: ProviderTransport {
    private let active = ArrayList<ActiveCurl>()
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
        try {
            let apiKey = match (credentials.resolve(provider, requestId)) {
                case domain.Result.Ok(value) => value
                case domain.Result.Err(error) => return domain.Result.Err(error)
            }
            if (apiKey.contains("\n") || apiKey.contains("\r") || apiKey.contains("\"")) {
                return domain.Result.Err(
                    domain.AgentError(
                        domain.AgentErrorKind.Configuration,
                        "model.invalid_api_key",
                        "provider API key contains unsafe header characters",
                        fields: [
                            domain.ErrorField(
                                "environment",
                                provider.apiKeyEnv
                            )
                        ]
                    )
                )
            }
            if (!exists(Path("target"))) {
                Directory.create("target", recursive: true)
            }
            let root = Directory.createTemp("target").toString()
            let requestPath = root + "/request.json"
            let configPath = root + "/curl.conf"
            let responseHeaderPath = root + "/response.headers"
            File.writeTo(requestPath, payload.toArray())
            File.writeTo(
                configPath,
                curlConfig(provider, apiKey, streaming).toArray()
            )
            let (chmodCode, _, _) = executeWithOutput(
                "chmod",
                ["600", configPath]
            )
            if (chmodCode != 0) {
                removeFile(configPath)
                return domain.Result.Err(
                    domain.AgentError(
                        domain.AgentErrorKind.PermissionDenied,
                        "model.credential_file_permissions",
                        "cannot protect temporary provider credential file"
                    )
                )
            }
            try {
                let arguments = ArrayList<String>()
                arguments.add("--silent")
                arguments.add("--show-error")
                arguments.add("--fail-with-body")
                appendCurlResponseCaptureArguments(arguments, responseHeaderPath)
                if (provider.timeoutMillis > 0) {
                    arguments.add("--max-time")
                    arguments.add(curlSeconds(provider.timeoutMillis))
                }
                arguments.add("--config")
                arguments.add(configPath)
                arguments.add("--data-binary")
                arguments.add("@" + requestPath)
                if (streaming) {
                    arguments.add("--no-buffer")
                }
                arguments.add(provider.endpoint())
                // Both streaming and captured requests must expose the same
                // cancellable SubProcess handle. The old executeWithOutput
                // path made non-streaming approval reviews impossible to stop.
                let (code, out, err) = executeStreaming(
                    arguments.toArray(),
                    if (streaming) { chunks } else { {_ => ()} },
                    {process => register(requestId, process)}
                )
                if (finish(requestId)) {
                    return domain.Result.Err(
                        domain.AgentError(
                            domain.AgentErrorKind.Cancelled,
                            "model.cancelled",
                            "model request was cancelled",
                            fields: [
                                domain.ErrorField(
                                    "request_id",
                                    requestId
                                )
                            ]
                        )
                    )
                }
                let body = String.fromUtf8(out)
                let responseHeaders = if (exists(Path(responseHeaderPath))) {
                    try {
                        String.fromUtf8(File.readFrom(responseHeaderPath))
                    } catch (_: Exception) {
                        ""
                    }
                } else {
                    ""
                }
                let processHttp = extractHttpStatus(String.fromUtf8(err))
                let http = HttpDiagnostic(
                    processHttp.status,
                    processHttp.diagnostic,
                    retryAfterMillis: max(processHttp.retryAfterMillis, extractRetryAfterHeader(responseHeaders))
                )
                if (code != 0) {
                    let diagnostic = (body + http.diagnostic).trimAscii()
                    return domain.Result.Err(
                        providerFailure(
                            code,
                            http.status,
                            diagnostic,
                            provider.id,
                            retryAfterMillis: http.retryAfterMillis
                        )
                    )
                }
                domain.Result.Ok(body)
            } finally {
                let _ = finish(requestId)
                let _ = removeIfExists(root, recursive: true)
            }
        } catch (error: Exception) {
            domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Transport,
                    "model.transport_internal",
                    error.message,
                    retryable: true,
                    fallbackAllowed: true
                )
            )
        } finally { credentials.complete(requestId) }
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        let credentialCancellation = credentials.cancel(requestId)
        activeLock.lock()
        try {
            for (item in active where item.requestId == requestId) {
                item.cancelled = true
                try {
                    item.process.terminate(force: true)
                } catch (_: Exception) {}
                return domain.Result.Ok(())
            }
            credentialCancellation
        } finally {
            activeLock.unlock()
        }
    }

    private func register(requestId: String, process: SubProcess): Unit {
        activeLock.lock()
        try {
            active.add(ActiveCurl(requestId, process))
        } finally {
            activeLock.unlock()
        }
    }

    private func finish(requestId: String): Bool {
        activeLock.lock()
        try {
            for (index in 0..active.size) {
                if (active[index].requestId == requestId) {
                    let cancelled = active[index].cancelled
                    active.remove(at: index)
                    return cancelled
                }
            }
            false
        } finally {
            activeLock.unlock()
        }
    }
}

func appendCurlResponseCaptureArguments(arguments: ArrayList<String>, responseHeaderPath: String): Unit {
    arguments.add("--write-out")
    arguments.add("%{stderr}__AXYNDRA_HTTP_STATUS__:%{http_code}\\n")
    arguments.add("--dump-header")
    // Keep protocol headers out of stdout. Non-streaming model replies are
    // decoded directly as JSON; writing headers to stdout made successful
    // replies begin with `HTTP/...` and fail at JSON byte zero.
    arguments.add(responseHeaderPath)
}

func providerFailure(
    processCode: Int64,
    httpStatus: Int64,
    diagnostic: String,
    providerId: String,
    retryAfterMillis!: Int64 = 0
): domain.AgentError {
    let normalized = diagnostic.toAsciiLower()
    let message = if (diagnostic == "") {
        "provider transport failed"
    } else {
        diagnostic
    }
    let fields = if (retryAfterMillis > 0) {
        [
            domain.ErrorField("provider_id", providerId),
            domain.ErrorField(
                "retry_after_ms",
                retryAfterMillis.toString()
            )
        ]
    } else {
        [domain.ErrorField("provider_id", providerId)]
    }
    if (httpStatus == 401 || httpStatus == 403) {
        return domain.AgentError(
            domain.AgentErrorKind.Authentication,
            "model.authentication",
            message,
            fields: fields
        )
    }
    if (httpStatus == 408 || httpStatus == 504 || processCode == 28) {
        return domain.AgentError(
            domain.AgentErrorKind.Timeout,
            "model.timeout",
            message,
            retryable: true,
            fallbackAllowed: true,
            fields: fields
        )
    }
    if (httpStatus == 429) {
        return domain.AgentError(
            domain.AgentErrorKind.RateLimited,
            "model.rate_limited",
            message,
            retryable: true,
            fallbackAllowed: true,
            fields: fields
        )
    }
    if (httpStatus >= 500 && httpStatus <= 599) {
        return domain.AgentError(
            domain.AgentErrorKind.Provider,
            "model.provider_error",
            message,
            retryable: true,
            fallbackAllowed: true,
            fields: fields
        )
    }
    if (processCode == 22) {
        if (normalized.contains("context_length") || normalized.contains("context window") || normalized.contains(
            "maximum context")) {
            return domain.AgentError(
                domain.AgentErrorKind.BudgetExceeded,
                "model.context_exceeded",
                message,
                fields: fields
            )
        }
        if (normalized.contains("rate_limit") || normalized.contains("too many requests")) {
            return domain.AgentError(
                domain.AgentErrorKind.RateLimited,
                "model.rate_limited",
                message,
                retryable: true,
                fallbackAllowed: true,
                fields: fields
            )
        }
        if (normalized.contains("authentication") || normalized.contains("invalid_api_key") || normalized.contains(
            "unauthorized")) {
            return domain.AgentError(
                domain.AgentErrorKind.Authentication,
                "model.authentication",
                message,
                fields: fields
            )
        }
        return domain.AgentError(
            domain.AgentErrorKind.Provider,
            "model.provider_error",
            message,
            retryable: true,
            fallbackAllowed: true,
            fields: fields
        )
    }
    domain.AgentError(
        domain.AgentErrorKind.Transport,
        "model.transport",
        message,
        retryable: true,
        fallbackAllowed: true,
        fields: fields
    )
}

class HttpDiagnostic {
    let status: Int64
    let diagnostic: String
    let retryAfterMillis: Int64

    init(status: Int64, diagnostic: String, retryAfterMillis!: Int64 = 0) {
        this.status = status
        this.diagnostic = diagnostic
        this.retryAfterMillis = retryAfterMillis
    }
}

func extractHttpStatus(stderr: String): HttpDiagnostic {
    let marker = "__AXYNDRA_HTTP_STATUS__:"
    var status: Int64 = 0
    var diagnostic = ""
    var retryAfter: Int64 = 0
    for (line in stderr.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith(marker)) {
            let authored = trimmed[marker.size..].trimAscii()
            try {
                status = Int64.parse(authored)
            } catch (_: Exception) {
                status = 0
            }
        } else if (trimmed.toAsciiLower().startsWith("retry-after:")) {
            let value = trimmed[12..].trimAscii()
            retryAfter = parseRetryAfter(value)
        } else if (trimmed != "") {
            if (diagnostic != "") {
                diagnostic += "\n"
            }
            diagnostic += line
        }
    }
    HttpDiagnostic(status, diagnostic, retryAfterMillis: retryAfter)
}

// Retry backoff parameters matching OMP's provider retry policy:
// 0.5s * 2^n exponential backoff, capped at 8s, with up to 25% jitter.
const BASE_RETRY_DELAY_MILLIS: Int64 = 500
const MAX_RETRY_DELAY_MILLIS: Int64 = 8000

func extractRetryAfterHeader(headers: String): Int64 {
    min(extractRetryAfterMillis(headers), MAX_RETRY_DELAY_MILLIS)
}

func parseRetryAfter(value: String): Int64 {
    min(parseRetryAfterMillis(value), MAX_RETRY_DELAY_MILLIS)
}

func curlSeconds(milliseconds: Int64): String {
    let seconds = milliseconds / 1000
    let remainder = milliseconds % 1000
    var fraction = remainder.toString()
    while (fraction.size < 3) {
        fraction = "0" + fraction
    }
    seconds.toString() + "." + fraction
}

class ActiveCurl {
    let requestId: String
    let process: SubProcess
    var cancelled: Bool = false

    init(requestId: String, process: SubProcess) {
        this.requestId = requestId
        this.process = process
    }
}

func executeStreaming(
    arguments: Array<String>,
    chunks: (String) -> Unit,
    started: (SubProcess) -> Unit
): (Int64, Array<Byte>, Array<Byte>) {
    let process = launch(
        "curl",
        arguments,
        stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe
    )
    started(process)
    let budget = BoundedOutputBudget(67108864)
    let errorFuture = spawn { readBounded(process.stdErrPipe, budget) }
    let output = ArrayList<Byte>()
    let line = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = process.stdOutPipe.read(buffer)
        if (count <= 0) {
            break
        }
        let accepted = budget.claim(count)
        for (index in 0..accepted) {
            let byte = buffer[index]
            output.add(byte)
            line.add(byte)
            if (byte == b'\n') {
                chunks(String.fromUtf8(line.toArray()))
                line.clear()
            }
        }
        if (accepted < count) {
            try { process.terminate(force: true) } catch (_: Exception) {}
            break
        }
    }
    if (!line.isEmpty()) {
        chunks(String.fromUtf8(line.toArray()))
    }
    let code = process.wait()
    let errors = errorFuture.get()
    if (budget.wasTruncated()) { throw IllegalStateException("provider response exceeds 64 MiB") }
    (code, output.toArray(), errors)
}

func forwardEventChunk(
    chunk: String,
    protocol: ProviderProtocol,
    events: domain.ModelEventSink
): Unit {
    try {
        let payload = match (sseDataLine(chunk.trimAscii())) { case Some(value) => value; case None => return }
        let projected = decodeLlmWireEventFrame(
            match (protocol) {
                case ProviderProtocol.Messages => LlmWireProtocol.Messages
                case ProviderProtocol.Responses => LlmWireProtocol.Responses
                case ProviderProtocol.Completions => LlmWireProtocol.ChatCompletions
            },
            payload
        )
        for (event in projected) { emitLlmWireEvent(event, protocol, events) }
    } catch (_: Exception) {}
}

func providerProtocolName(protocol: ProviderProtocol): String {
    match (protocol) {
        case ProviderProtocol.Messages => "messages"
        case ProviderProtocol.Responses => "responses"
        case ProviderProtocol.Completions => "chat_completions"
    }
}

func emitLlmWireEvent(
    event: LlmWireEvent,
    protocol: ProviderProtocol,
    events: domain.ModelEventSink
): Unit {
    match (event.kind) {
        case LlmWireEventKind.StreamStarted => events(domain.ModelEvent.ProviderProgress(
            domain.ProviderStreamEvent.StreamStarted(event.terminalEventKind)
        ))
        case LlmWireEventKind.ContentBlockStarted => events(domain.ModelEvent.ProviderProgress(
            domain.ProviderStreamEvent.ContentBlockStarted(event.blockIndex, event.blockKind)
        ))
        case LlmWireEventKind.TextDelta => events(domain.ModelEvent.TextDelta(event.text))
        case LlmWireEventKind.ReasoningDelta => events(domain.ModelEvent.ReasoningDelta(event.text))
        case LlmWireEventKind.ToolCallStarted => events(domain.ModelEvent.ToolCallStarted(event.callId, event.text))
        case LlmWireEventKind.ToolArgumentsDelta => events(domain.ModelEvent.ToolArgumentsDelta(event.callId, event.text))
        case LlmWireEventKind.ContentBlockCompleted =>
            events(domain.ModelEvent.ProviderProgress(
                domain.ProviderStreamEvent.ContentBlockCompleted(
                    event.blockIndex,
                    event.blockKind
                )
            ))
            if (event.callId != "") {
                events(domain.ModelEvent.ToolCallCompleted(event.callId))
            }
        case LlmWireEventKind.MessageTerminalObserved =>
            events(domain.ModelEvent.ProviderProgress(
                domain.ProviderStreamEvent.MessageTerminalObserved(
                    domain.TerminalEvidence(
                        providerProtocolName(protocol),
                        event.terminalEventKind,
                        rawStopReason: event.rawStopReason,
                        messageTerminalObserved: true,
                        adapterVersion: "llm4cj-wire-v2"
                    )
                )
            ))
        case LlmWireEventKind.UsageDelta =>
            events(domain.ModelEvent.ProviderProgress(
                domain.ProviderStreamEvent.UsageDelta(
                    event.inputTokens,
                    event.outputTokens
                )
            ))
        case LlmWireEventKind.UsageCompleted =>
            events(domain.ModelEvent.UsageUpdated(event.inputTokens, event.outputTokens))
            events(domain.ModelEvent.ProviderProgress(
                domain.ProviderStreamEvent.UsageCompleted(
                    event.inputTokens,
                    event.outputTokens
                )
            ))
        case LlmWireEventKind.ProviderError => events(domain.ModelEvent.ProviderProgress(
            domain.ProviderStreamEvent.ProviderError(event.text)
        ))
        case LlmWireEventKind.StreamTransportClosed => events(domain.ModelEvent.ProviderProgress(
            domain.ProviderStreamEvent.StreamTransportClosed
        ))
        case LlmWireEventKind.Completed => events(domain.ModelEvent.Completed)
    }
}

public class ProviderModelPort <: ports.ModelPort {
    private let provider: ProviderSpec
    private let transport: ProviderTransport

    public init(provider: ProviderSpec, transport: ProviderTransport) {
        this.provider = provider
        this.transport = transport
    }

    public func execute(
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        let messagesProtocol = match (provider.protocol) {
            case ProviderProtocol.Messages => true
            case _ => false
        }
        let messagesFast = messagesProtocol &&
            provider.provider.toAsciiLower() == "anthropic" &&
            request.serviceTier == "priority"
        if (messagesProtocol &&
            request.serviceTier != "" && !messagesFast) {
            return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.InvalidInput,
                "model.service_tier_unsupported",
                "Messages fast mode requires the explicit Anthropic priority tier",
                fields: [
                    domain.ErrorField("provider_id", provider.id),
                    domain.ErrorField("service_tier", request.serviceTier)
                ]
            ))
        }
        let normalized = domain.ModelRequest(
            if (request.model.trimAscii() == "") {
                provider.model
            } else {
                request.model
            },
            request.messages,
            system: request.system,
            tools: request.tools,
            thinking: request.thinking,
            maxOutputTokens: request.maxOutputTokens,
            wireMaxOutputTokens: request.wireMaxOutputTokens,
            streaming: request.streaming,
            parallelToolCalls: request.parallelToolCalls,
            requestId: request.requestId,
            serviceTier: request.serviceTier,
            cachePolicy: request.cachePolicy,
            toolChoice: request.toolChoice,
            structuredOutput: request.structuredOutput,
            cacheKey: request.cacheKey,
            transportHardTimeoutMillis: request.transportHardTimeoutMillis,
            resolvedPolicy: request.resolvedPolicy
        )
        match (provider.capabilities.validate(normalized)) {
            case domain.Result.Ok(_) => ()
            case domain.Result.Err(error) => return domain.Result.Err(error)
        }
        match (validateModelRequestContent(normalized)) {
            case domain.Result.Ok(_) => ()
            case domain.Result.Err(error) => return domain.Result.Err(error)
        }
        let payload = match (provider.dialect) {
            case ProviderDialect.AnthropicMessages | ProviderDialect.GenericMessages =>
                encodeMessagesRequest(normalized)
            case ProviderDialect.DeepSeekMessages => encodeDeepSeekMessagesRequest(normalized)
            case ProviderDialect.OpenAiResponses => encodeResponsesRequest(normalized)
            case ProviderDialect.OpenAiChat | ProviderDialect.GenericChat =>
                encodeCompletionsRequest(normalized)
            case ProviderDialect.DeepSeekChat => encodeDeepSeekChatRequest(normalized)
        }
        // A streaming Core request with no attempt hard deadline is governed
        // by Core's idle watchdog and Run wall budget. Non-streaming/direct
        // callers retain the configured provider timeout.
        let transportTimeout = if (request.streaming && request.resolvedPolicy.isSome() &&
            request.transportHardTimeoutMillis == 0) {
            0
        } else {
            max(provider.timeoutMillis, request.transportHardTimeoutMillis)
        }
        let wireProvider = if (messagesFast || transportTimeout != provider.timeoutMillis) {
            ProviderSpec(
                provider.id,
                provider.protocol,
                provider.model,
                provider.baseUrl,
                provider.apiKeyEnv,
                credentialFile: provider.credentialFile,
                timeoutMillis: transportTimeout,
                provider: provider.provider,
                messagesFastMode: messagesFast,
                dialect: Some(provider.dialect),
                endpointMaxOutputTokens: provider.endpointMaxOutputTokens,
                capabilities: provider.capabilities
            )
        } else {
            provider
        }
        let streamEvents = if (request.streaming) {
            {
                chunk: String => forwardEventChunk(chunk, provider.protocol, events)
            }
        } else {
            {_: String => ()}
        }
        match (transport.post(
            wireProvider,
            payload,
            request.streaming,
            request.requestId,
            streamEvents
        )) {
            case domain.Result.Err(error) => domain.Result.Err(
                normalizeProviderAttemptFailure(error)
            )
            case domain.Result.Ok(body) =>
                if (request.streaming) {
                    events(domain.ModelEvent.ProviderProgress(
                        domain.ProviderStreamEvent.StreamTransportClosed
                    ))
                }
                let reply = decodeProviderReply(
                    provider,
                    body,
                    request.streaming,
                    if (request.streaming) {
                        {_ => ()}
                    } else {
                        events
                    },
                    request.structuredOutput
                )
                if (request.streaming && reply.isOk()) {
                    events(domain.ModelEvent.Completed)
                }
                reply
        }
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        transport.cancel(requestId)
    }
}

func normalizeProviderAttemptFailure(error: domain.AgentError): domain.AgentError {
    if (error.attemptFailure.isSome()) { return error }
    let kind: ?domain.AttemptFailureKind = match (error.kind) {
        case domain.AgentErrorKind.Timeout => Some(
            domain.AttemptFailureKind.ProviderTransportError
        )
        case domain.AgentErrorKind.Transport => Some(
            domain.AttemptFailureKind.ProviderTransportError
        )
        case domain.AgentErrorKind.Protocol => Some(
            domain.AttemptFailureKind.ProviderProtocolError
        )
        case domain.AgentErrorKind.Cancelled => Some(
            domain.AttemptFailureKind.UserCancelled
        )
        case _ => None
    }
    match (kind) {
        case None => error
        case Some(value) => domain.AgentError(
            error.kind, error.code, error.message,
            retryable: error.retryable,
            fallbackAllowed: error.fallbackAllowed,
            fields: error.fields,
            attemptFailure: Some(domain.AttemptFailure(value))
        )
    }
}

public func defaultProviderCapabilities(): domain.ModelCapabilities {
    domain.ModelCapabilities(
        toolCalling: true,
        parallelToolCalling: true,
        reasoning: true,
        vision: false,
        // ProviderSpec cannot infer these model/endpoint-specific features.
        // Product and SDK composition roots must opt in with real catalog
        // metadata rather than treating protocol compatibility as capability.
        structuredOutput: false,
        promptCache: false,
        contextWindowTokens: 1000000,
        maxOutputTokens: 200000
    )
}

public class FixtureModelPort <: ports.ModelPort {
    private let failFirst: Bool
    private var calls: Int64 = 0
    // Last request's thinking level, for contract probes (e.g. plan mode
    // must force High even when the session default is lower).
    public var lastThinking: domain.ThinkingLevel = domain.ThinkingLevel.Medium
    // Fixture-only observation point for end-to-end Product request contracts.
    // Production transports never read or populate this field.
    public var lastRequest: ?domain.ModelRequest = None

    public init(failFirst!: Bool = false) {
        this.failFirst = failFirst
    }

    public func execute(
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        lastRequest = Some(request)
        lastThinking = request.thinking
        calls += 1
        if (failFirst && calls == 1) {
            return domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Transport,
                    "fixture.transport",
                    "fixture transport failure",
                    retryable: true,
                    fallbackAllowed: true
                )
            )
        }
        let lastText = if (request.messages.isEmpty()) {
            ""
        } else {
            messageText(request.messages[request.messages.size - 1])
        }
        if (lastText.startsWith("[plan-review approved ") &&
            lastText.contains("FIXTURE-APPROVED-PLAN-EXECUTION-FAILURE")) {
            return domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Transport,
                    "fixture.plan_execution_failed",
                    "fixture approved-plan execution failed",
                    retryable: false,
                    fallbackAllowed: false
                )
            )
        }
        if (request.system.contains("COMPACTION_SEMANTIC_SUMMARIZER")) {
            if (lastText.contains("FIXTURE-COMPACTION-SUMMARY-FAILURE")) {
                return domain.Result.Err(
                    domain.AgentError(
                        domain.AgentErrorKind.Transport,
                        "fixture.compaction_summary_failed",
                        "fixture compaction summarizer failed",
                        retryable: false,
                        fallbackAllowed: true
                    )
                )
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.Text,
                            text: "The session established concrete facts and left clearly identified work for the next turn."
                        )
                    ],
                    stopReason: "end_turn",
                    inputTokens: request.messages.size,
                    outputTokens: 18,
                    providerId: "fixture",
                    responseId: "fixture-compaction-summary-" + calls.toString()
                )
            )
        }
        if (request.system.contains("INDEPENDENT_APPROVAL_REVIEWER")) {
            let normalized = lastText.toAsciiLower()
            let decision = if (normalized.contains("\"sensitive_data\"") || normalized.contains("\"system_change\"") ||
                normalized.contains("rm -rf /")) {
                "{\"decision\":\"deny\",\"reason\":\"The operation crosses a permanent safety boundary or exposes sensitive data.\",\"riskLevel\":\"critical\",\"approvedCapabilities\":[]}"
            } else if (normalized.contains("\"git_destructive\"") || normalized.contains("\"outside_workspace\"") ||
                normalized.contains("\"network\"")) {
                "{\"decision\":\"ask_user\",\"reason\":\"The operation has external or destructive side effects that require explicit user confirmation.\",\"riskLevel\":\"high\",\"approvedCapabilities\":[]}"
            } else {
                "{\"decision\":\"approve\",\"reason\":\"The scoped operation matches the user request and remains within the workspace.\",\"riskLevel\":\"low\",\"approvedCapabilities\":[\"workspace.write\"]}"
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [domain.ModelBlock(domain.ModelBlockKind.Text, text: decision)],
                    stopReason: "end_turn",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-approval-" + calls.toString()
                )
            )
        }
        if ((lastText == "fixture approval safe" || lastText == "fixture approval dangerous" || lastText ==
            "fixture approval ask" || lastText == "fixture approval execution failure") && hasTool(request.tools,
            if (lastText == "fixture approval safe" || lastText == "fixture approval execution failure") {
                "write"
            } else {
                "bash"
            })) {
            let block = if (lastText == "fixture approval safe" || lastText == "fixture approval execution failure") {
                domain.ModelBlock(
                    domain.ModelBlockKind.ToolCall,
                    callId: if (lastText == "fixture approval safe") {
                        "fixture-approval-safe"
                    } else {
                        "fixture-approval-execution-failure"
                    },
                    name: "write",
                    arguments: domain.objectValue(
                        [
                            domain.ValueField("path", domain.textValue(if (lastText == "fixture approval safe") {
                                "tmp/result.txt"
                            } else {
                                "/tmp/axyndra-approval-missing-parent/child.txt"
                            })),
                            domain.ValueField("content", domain.textValue("hello\n"))
                        ]
                    )
                )
            } else {
                domain.ModelBlock(
                    domain.ModelBlockKind.ToolCall,
                    callId: "fixture-approval-risk",
                    name: "bash",
                    arguments: domain.objectValue(
                        [domain.ValueField("command",
                            domain.textValue(if (lastText == "fixture approval dangerous") {
                                "rm -rf /"
                            } else {
                                "git push --force origin main"
                            }))])
                )
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [block],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-approval-tool-" + calls.toString()
                )
            )
        }
        match (fixtureHubProcessBlock(lastText)) {
            case Some(block) =>
                if (hasTool(request.tools, "hub")) {
                    if (request.streaming) {
                        events(
                            domain.ModelEvent.ToolCallStarted(
                                block.callId,
                                "hub"
                            )
                        )
                        events(domain.ModelEvent.ToolCallCompleted(block.callId))
                        events(domain.ModelEvent.Completed)
                    }
                    return domain.Result.Ok(
                        fixtureTerminalReply(
                            [block],
                            stopReason: "tool_use",
                            inputTokens: request.messages.size,
                            outputTokens: 1,
                            providerId: "fixture",
                            responseId: "fixture-" + calls.toString()
                        )
                    )
                }
            case None => ()
        }
        if (lastText == "fixture ask" && hasTool(request.tools, "ask")) {
            let block = domain.ModelBlock(
                domain.ModelBlockKind.ToolCall,
                callId: "fixture-ask-call",
                name: "ask",
                arguments: domain.objectValue(
                    [
                        domain.ValueField(
                            "questions",
                            domain.listValue(
                                [
                                    domain.objectValue(
                                        [
                                            domain.ValueField("id", domain.textValue("features")),
                                            domain.ValueField(
                                                "question",
                                                domain.textValue("Which features should be enabled?")
                                            ),
                                            domain.ValueField(
                                                "options",
                                                domain.listValue(
                                                    [
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField("label", domain.textValue("Search")),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Fast workspace lookup")
                                                                )
                                                            ]
                                                        ),
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField("label", domain.textValue("Export")),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Portable reports")
                                                                ),
                                                                domain.ValueField(
                                                                    "preview",
                                                                    domain.textValue("HTML and JSON")
                                                                )
                                                            ]
                                                        )
                                                    ]
                                                )
                                            ),
                                            domain.ValueField("multi", domain.boolValue(true)),
                                            domain.ValueField("recommended", domain.integerValue(1))
                                        ]
                                    ),
                                    domain.objectValue(
                                        [
                                            domain.ValueField("id", domain.textValue("verification")),
                                            domain.ValueField(
                                                "question",
                                                domain.textValue("Which verification should run?")
                                            ),
                                            domain.ValueField(
                                                "options",
                                                domain.listValue(
                                                    [
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField(
                                                                    "label",
                                                                    domain.textValue("Node tests")
                                                                ),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Run the core engine contract")
                                                                )
                                                            ]
                                                        ),
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField(
                                                                    "label",
                                                                    domain.textValue("Manual only")
                                                                ),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Skip automated verification")
                                                                )
                                                            ]
                                                        )
                                                    ]
                                                )
                                            ),
                                            domain.ValueField("recommended", domain.integerValue(0))
                                        ]
                                    )
                                ]
                            )
                        )
                    ]
                )
            )
            if (request.streaming) {
                events(domain.ModelEvent.ToolCallStarted(block.callId, "ask"))
                events(domain.ModelEvent.ToolCallCompleted(block.callId))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [block],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-ask"
                )
            )
        }
        if ((lastText == "fixture plan write" || lastText.startsWith("Plan mode protocol correction:")) && hasTool(
            request.tools, "plan_write")) {
            let block = domain.ModelBlock(
                domain.ModelBlockKind.ToolCall,
                callId: "fixture-plan-call",
                name: "plan_write",
                arguments: domain.objectValue(
                    [
                        domain.ValueField(
                            "content",
                            domain.textValue(
                                "Goal: ship a plan\nConstraints: read-only\n" +
                                    "Approach: inspect then write\nAcceptance: contract passes\n" + "Unresolved: none")
                        )
                    ]
                )
            )
            if (request.streaming) {
                events(domain.ModelEvent.ToolCallStarted(block.callId, "plan_write"))
                events(domain.ModelEvent.ToolCallCompleted(block.callId))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [block],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-plan"
                )
            )
        }
        if (lastText == "fixture task batch" && hasTool(request.tools, "task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-batch-call",
                        "task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-batch-call"))
                events(domain.ModelEvent.Completed)
            }
            let items = ArrayList<domain.AgentValue>()
            for (name in ["fixture-batch-a", "fixture-batch-b"]) {
                items.add(
                    domain.objectValue(
                        [
                            domain.ValueField(
                                "name",
                                domain.textValue(name)
                            ),
                            domain.ValueField(
                                "agent",
                                domain.textValue("reviewer")
                            ),
                            domain.ValueField(
                                "task",
                                domain.textValue("child fixture yield")
                            )
                        ]
                    )
                )
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-batch-call",
                            name: "task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("shared fixture context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(items.toArray())
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture hub jobs" && hasTool(request.tools, "hub")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-hub-jobs-call",
                        "hub"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-hub-jobs-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-hub-jobs-call",
                            name: "hub",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("jobs")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if ((lastText == "fixture hub inbox" || lastText == "fixture hub list") && hasTool(request.tools, "hub")) {
            let op = if (lastText == "fixture hub inbox") {
                "inbox"
            } else {
                "list"
            }
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-hub-" + op + "-call",
                        "hub"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-hub-" + op + "-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-hub-" + op + "-call",
                            name: "hub",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue(op)
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture hub send child" && hasTool(request.tools, "hub")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-hub-send-child-call",
                        "hub"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-hub-send-child-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-hub-send-child-call",
                            name: "hub",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("send")
                                    ),
                                    domain.ValueField(
                                        "to",
                                        domain.textValue("fixture-hub-child")
                                    ),
                                    domain.ValueField(
                                        "message",
                                        domain.textValue("follow up child")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task write" && hasTool(request.tools, "task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-write-call",
                        "task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-write-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-write-call",
                            name: "task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("fixture write child context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-write-child")
                                                        ),
                                                        domain.ValueField(
                                                            "agent",
                                                            domain.textValue("task")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture write")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task hub send" && hasTool(request.tools, "task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-hub-call",
                        "task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-hub-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-hub-call",
                            name: "task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("fixture hub child context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-hub-child")
                                                        ),
                                                        domain.ValueField(
                                                            "agent",
                                                            domain.textValue("reviewer")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture hub send")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if ((lastText == "fixture async bash" || lastText == "fixture async bash wait") && hasTool(request.tools, "bash")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-async-bash-call",
                        "bash"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-async-bash-call"))
                events(domain.ModelEvent.Completed)
            }
            let command = if (lastText == "fixture async bash wait") {
                "sleep 5"
            } else {
                "printf async-bash-result"
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-async-bash-call",
                            name: "bash",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "command",
                                        domain.textValue(command)
                                    ),
                                    domain.ValueField(
                                        "async",
                                        domain.boolValue(true)
                                    ),
                                    domain.ValueField(
                                        "timeout",
                                        domain.integerValue(10)
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task" && hasTool(request.tools, "task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-call",
                        "task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-call",
                            name: "task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("single child fixture context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-child")
                                                        ),
                                                        domain.ValueField(
                                                            "agent",
                                                            domain.textValue("reviewer")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture yield")
                                                        ),
                                                        domain.ValueField(
                                                            "outputSchema",
                                                            domain.objectValue(
                                                                [
                                                                    domain.ValueField(
                                                                        "type",
                                                                        domain.textValue("object")
                                                                    ),
                                                                    domain.ValueField(
                                                                        "properties",
                                                                        domain.objectValue(
                                                                            [
                                                                                domain.ValueField(
                                                                                    "answer",
                                                                                    domain.objectValue(
                                                                                        [
                                                                                            domain.ValueField(
                                                                                                "type",
                                                                                                domain.textValue(
                                                                                                    "string")
                                                                                            )
                                                                                        ]
                                                                                    )
                                                                                )
                                                                            ]
                                                                        )
                                                                    ),
                                                                    domain.ValueField(
                                                                        "required",
                                                                        domain.listValue(
                                                                            [domain.textValue("answer")])
                                                                    )
                                                                ]
                                                            )
                                                        ),
                                                        domain.ValueField(
                                                            "schemaMode",
                                                            domain.textValue("strict")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task cancel" && hasTool(request.tools, "task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-cancel-call",
                        "task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-cancel-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-cancel-call",
                            name: "task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("fixture cancellation context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-cancel-child")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture bash wait")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture yield" && hasTool(request.tools, "yield")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-yield-call",
                        "yield"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-yield-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-yield-call",
                            name: "yield",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "result",
                                        domain.objectValue(
                                            [
                                                domain.ValueField(
                                                    "data",
                                                    domain.objectValue(
                                                        [
                                                            domain.ValueField(
                                                                "answer",
                                                                domain.textValue("reviewed")
                                                            )
                                                        ]
                                                    )
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture bash wait" && hasTool(request.tools, "bash")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-child-bash-wait",
                        "bash"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-child-bash-wait"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-child-bash-wait",
                            name: "bash",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "command",
                                        domain.textValue("sleep 5")
                                    ),
                                    domain.ValueField(
                                        "timeout",
                                        domain.integerValue(10000)
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture write" && hasTool(request.tools, "write")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-child-write",
                        "write"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-child-write"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-child-write",
                            name: "write",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "path",
                                        domain.textValue("child-approved.txt")
                                    ),
                                    domain.ValueField(
                                        "content",
                                        domain.textValue("written by child\n")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture hub send" && hasTool(request.tools, "hub")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-child-hub-send",
                        "hub"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-child-hub-send"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-child-hub-send",
                            name: "hub",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("send")
                                    ),
                                    domain.ValueField(
                                        "to",
                                        domain.textValue("Main")
                                    ),
                                    domain.ValueField(
                                        "message",
                                        domain.textValue("child report delivered")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture vnext read" && hasTool(request.tools, "read")) {
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-vnext-read",
                            name: "read",
                            arguments: domain.objectValue([
                                domain.ValueField("path", domain.textValue("input.txt"))
                            ])
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-vnext-read-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture host uri read" && hasTool(request.tools, "read")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-host-uri-read",
                        "read"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-host-uri-read"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-host-uri-read",
                            name: "read",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "path",
                                        domain.textValue("hostdoc://guide")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture host uri write" && hasTool(request.tools, "write")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-host-uri-write",
                        "write"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-host-uri-write"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-host-uri-write",
                            name: "write",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "path",
                                        domain.textValue("hostdoc://guide")
                                    ),
                                    domain.ValueField(
                                        "content",
                                        domain.textValue("updated by fixture")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture host tool" && hasTool(request.tools, "host_echo")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-host-call",
                        "host_echo"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-host-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-host-call",
                            name: "host_echo",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "text",
                                        domain.textValue("from fixture")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "Continue working on the active goal." && hasTool(request.tools, "goal")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-goal-complete",
                        "goal"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-goal-complete"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-goal-complete",
                            name: "goal",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("complete")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        let text = if (request.messages.size == 0) {
            "fixture response"
        } else if (lastText == "fixture split json secrets") {
            "prefix sk-app-SPLIT-PRIVATE-VALUE suffix\n" +
                "Authorization: Bearer APP-HEADER-SECRET\nvisible-app-text\n" +
                "-----BEGIN PRIVATE KEY-----\nAPP-PEM-PRIVATE-BODY\n-----END PRIVATE KEY-----\n"
        } else {
            "fixture response for " + messageText(request.messages[request.messages.size - 1])
        }
        if (request.streaming) {
            if (lastText == "fixture split json secrets") {
                events(domain.ModelEvent.TextDelta("prefix sk-app-SPLIT"))
                events(domain.ModelEvent.TextDelta(
                    "-PRIVATE-VALUE suffix\nAuthorization: Bear"
                ))
                events(domain.ModelEvent.TextDelta(
                    "er APP-HEADER-SECRET\nvisible-app-text\n"
                ))
                events(domain.ModelEvent.TextDelta(
                    "-----BEGIN PRIVATE KEY-----\nAPP-PEM-"
                ))
                events(domain.ModelEvent.TextDelta(
                    "PRIVATE-BODY\n-----END PRIVATE KEY-----\n"
                ))
            } else {
                events(domain.ModelEvent.TextDelta(text))
            }
            events(domain.ModelEvent.Completed)
        }
        domain.Result.Ok(
            fixtureTerminalReply(
                [domain.ModelBlock(domain.ModelBlockKind.Text, text: text)],
                stopReason: "end_turn",
                inputTokens: request.messages.size,
                outputTokens: 1,
                providerId: "fixture",
                responseId: "fixture-" + calls.toString()
            )
        )
    }
}

// Fixture responses still cross the same strict provider-terminal boundary as
// real adapters. Keeping the evidence here prevents tests and local product
// modes from reviving the removed "HTTP success implies complete" shortcut.
func fixtureTerminalReply(
    blocks: Array<domain.ModelBlock>,
    stopReason!: String = "end_turn",
    inputTokens!: Int64 = 0,
    outputTokens!: Int64 = 0,
    providerId!: String = "fixture",
    responseId!: String = ""
): domain.ModelReply {
    var hasTool = false
    var hasRefusal = false
    for (block in blocks) {
        match (block.kind) {
            case domain.ModelBlockKind.ToolCall => hasTool = true
            case domain.ModelBlockKind.Refusal => hasRefusal = true
            case _ => ()
        }
    }
    domain.ModelReply(
        blocks,
        stopReason: stopReason,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        providerId: providerId,
        responseId: responseId,
        terminalEvidence: Some(domain.TerminalEvidence(
            "fixture", "fixture_terminal", rawStopReason: stopReason,
            messageTerminalObserved: true, streamEofObserved: true,
            adapterVersion: "fixture-v1"
        )),
        completionDisposition: if (hasTool) {
            domain.CompletionDisposition.ToolUse
        } else { domain.CompletionDisposition.Complete },
        decisionOutcome: if (hasRefusal) {
            domain.DecisionOutcome.Refusal
        } else if (hasTool) {
            domain.DecisionOutcome.ToolCalls
        } else { domain.DecisionOutcome.Response },
        validationVersion: 1
    )
}

func fixtureHubProcessBlock(prompt: String): ?domain.ModelBlock {
    let prefix = "fixture hub process "
    if (!prompt.startsWith(prefix)) {
        return None
    }
    let action = prompt[prefix.size..prompt.size]
    let fields = ArrayList<domain.ValueField>()
    let op: String
    match (action) {
        case "start" =>
            op = "start"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "application",
                    domain.textValue("/bin/bash")
                )
            )
            fields.add(
                domain.ValueField(
                    "args",
                    domain.listValue(
                        [
                            domain.textValue("-lc"),
                            domain.textValue(
                                "printf 'READY\\n'; " + "while IFS= read -r -d $'\\r' line; do " +
                                    "printf 'ECHO:%s\\n' \"$line\"; " + "[ \"$line\" = quit ] && exit 0; done")
                        ]
                    )
                )
            )
            fields.add(
                domain.ValueField(
                    "pty",
                    domain.boolValue(false)
                )
            )
            fields.add(
                domain.ValueField(
                    "ready",
                    domain.objectValue(
                        [
                            domain.ValueField(
                                "log",
                                domain.textValue("READY")
                            ),
                            domain.ValueField(
                                "timeout",
                                domain.integerValue(2)
                            )
                        ]
                    )
                )
            )
        case "start-again" =>
            op = "start"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "application",
                    domain.textValue("/bin/bash")
                )
            )
            fields.add(
                domain.ValueField(
                    "args",
                    domain.listValue(
                        [
                            domain.textValue("-lc"),
                            domain.textValue("printf 'SECOND\\n'")
                        ]
                    )
                )
            )
            fields.add(
                domain.ValueField(
                    "pty",
                    domain.boolValue(false)
                )
            )
        case "logs" =>
            op = "logs"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "lines",
                    domain.integerValue(20)
                )
            )
        case "send" =>
            op = "send"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "text",
                    domain.textValue("hello")
                )
            )
        case "wait" =>
            op = "wait"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "pattern",
                    domain.textValue("ECHO:hello")
                )
            )
            fields.add(
                domain.ValueField(
                    "timeout",
                    domain.integerValue(2)
                )
            )
        case "describe" =>
            op = "describe"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
        case "restart" =>
            op = "restart"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
        case "ps" => op = "ps"
        case "stop" =>
            op = "stop"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
        case "persist" =>
            op = "start"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-persist")
                )
            )
            fields.add(
                domain.ValueField(
                    "application",
                    domain.textValue("/bin/true")
                )
            )
            fields.add(
                domain.ValueField(
                    "persist",
                    domain.boolValue(true)
                )
            )
        case _ => return None
    }
    fields.add(domain.ValueField("op", domain.textValue(op)))
    Some(
        domain.ModelBlock(
            domain.ModelBlockKind.ToolCall,
            callId: "fixture-hub-process-" + action + "-call",
            name: "hub",
            arguments: domain.objectValue(fields.toArray())
        )
    )
}

func hasTool(
    tools: Array<domain.ModelToolDefinition>,
    name: String
): Bool {
    for (tool in tools where tool.name == name) {
        return true
    }
    false
}

public class LifecycleModelPort <: ports.ModelPort {
    private let primary: ports.ModelPort
    private let fallback: ports.ModelPort
    private let maxAttempts: Int64

    public init(
        primary: ports.ModelPort,
        fallback: ports.ModelPort,
        maxAttempts!: Int64 = 3
    ) {
        if (maxAttempts < 1) {
            throw IllegalArgumentException("model max attempts must be positive")
        }
        this.primary = primary
        this.fallback = fallback
        this.maxAttempts = maxAttempts
    }

    public func execute(
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        let primaryResult = executeWithRetry(primary, request, events)
        match (primaryResult) {
            case domain.Result.Ok(reply) => domain.Result.Ok(reply)
            case domain.Result.Err(error) =>
                if (error.fallbackAllowed) {
                    executeWithRetry(fallback, request, events)
                } else {
                    domain.Result.Err(error)
                }
        }
    }

    private func executeWithRetry(
        port: ports.ModelPort,
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        var attempt: Int64 = 1
        while (attempt <= maxAttempts) {
            let result = port.execute(request, events)
            match (result) {
                case domain.Result.Ok(reply) => return domain.Result.Ok(reply)
                case domain.Result.Err(error) =>
                    if (!error.retryable || attempt == maxAttempts) {
                        return domain.Result.Err(error)
                    }
            }
            attempt += 1
        }
        domain.Result.Err(
            domain.AgentError(
                domain.AgentErrorKind.Internal,
                "model.retry_exhausted",
                "model retry loop exhausted without a result"
            )
        )
    }
}

public class RetryControl {
    private let lock = Mutex()
    private var enabled = true
    private let aborted = ArrayList<String>()

    public init(enabled!: Bool = true) {
        this.enabled = enabled
    }

    public func setEnabled(value: Bool): Unit {
        lock.lock()
        try {
            enabled = value
        } finally {
            lock.unlock()
        }
    }

    public func isEnabled(): Bool {
        lock.lock()
        try {
            enabled
        } finally {
            lock.unlock()
        }
    }

    public func begin(requestId: String): Unit {
        lock.lock()
        try {
            removeRequest(aborted, requestId)
        } finally {
            lock.unlock()
        }
    }

    public func abort(requestId: String): Unit {
        lock.lock()
        try {
            if (!containsRequest(aborted, requestId)) {
                aborted.add(requestId)
            }
        } finally {
            lock.unlock()
        }
    }

    public func shouldRetry(requestId: String): Bool {
        lock.lock()
        try {
            enabled && !containsRequest(aborted, requestId)
        } finally {
            lock.unlock()
        }
    }

    public func finish(requestId: String): Unit {
        lock.lock()
        try {
            removeRequest(aborted, requestId)
        } finally {
            lock.unlock()
        }
    }

    private func containsRequest(
        values: ArrayList<String>,
        requestId: String
    ): Bool {
        for (value in values where value == requestId) {
            return true
        }
        false
    }

    private func removeRequest(
        values: ArrayList<String>,
        requestId: String
    ): Unit {
        for (index in 0..values.size) {
            if (values[index] == requestId) {
                values.remove(at: index)
                return
            }
        }
    }
}

func retryAfterMillis(error: domain.AgentError): Int64 {
    match (error.field("retry_after_ms")) {
        case Some(value) =>
            let parsed = try {
                Int64.parse(value)
            } catch (_: Exception) {
                0
            }
            min(max(0, parsed), MAX_RETRY_DELAY_MILLIS)
        case None => 0
    }
}

public class RetryingModelPort <: ports.ModelPort {
    private let inner: ports.ModelPort
    private let control: RetryControl
    private let maxAttempts: Int64

    public init(
        inner: ports.ModelPort,
        control: RetryControl,
        maxAttempts!: Int64 = 3
    ) {
        if (maxAttempts < 1) {
            throw IllegalArgumentException("model max attempts must be positive")
        }
        this.inner = inner
        this.control = control
        this.maxAttempts = maxAttempts
    }

    public func execute(
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        control.begin(request.requestId)
        try {
            var attempt: Int64 = 1
            while (attempt <= maxAttempts) {
                let result = inner.execute(request, events)
                match (result) {
                    case domain.Result.Ok(reply) => return domain.Result.Ok(reply)
                    case domain.Result.Err(error) =>
                        if (!error.retryable || attempt == maxAttempts || !control.shouldRetry(request.requestId)) {
                            return domain.Result.Err(error)
                        }
                        // Exponential backoff with up to 25% jitter, honoring
                        // a server-suggested retry-after hint when present.
                        let serverDelay = retryAfterMillis(error)
                        let backoffMillis = min(
                            BASE_RETRY_DELAY_MILLIS * (1 << (attempt - 1)),
                            MAX_RETRY_DELAY_MILLIS
                        )
                        let jitter = backoffMillis / 4
                        let delay = max(
                            serverDelay,
                            backoffMillis - jitter + (backoffMillis / 2)
                        )
                        sleep(Duration.millisecond * delay)
                }
                attempt += 1
            }
            domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Internal,
                    "model.retry_exhausted",
                    "model retry loop exhausted without a result"
                )
            )
        } finally {
            control.finish(request.requestId)
        }
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        control.abort(requestId)
        inner.cancel(requestId)
    }
}

public func fixtureModelPort(): ports.ModelPort {
    FixtureModelPort()
}

public func primaryFixtureModelPort(): ports.ModelPort {
    FixtureModelPort(failFirst: true)
}

public func providerModelPort(
    provider: ProviderSpec,
    transport!: ProviderTransport = NativeProviderTransport()
): ports.ModelPort {
    ProviderModelPort(provider, transport)
}

public func encodeAgentValue(value: domain.AgentValue): String {
    encodeJson(value)
}

public func decodeAgentValue(
    source: String,
    maxBytes!: Int64 = 1048576
): domain.Result<domain.AgentValue> {
    try {
        domain.Result.Ok(parseJson(source, maxBytes: maxBytes))
    } catch (error: JsonError) {
        domain.Result.Err(
            domain.AgentError(
                domain.AgentErrorKind.Protocol,
                "value.invalid_json",
                error.message,
                fields: [
                    domain.ErrorField("json_error_kind", jsonErrorKindName(error.kind))
                ]
            )
        )
    }
}

func toLlmWireThinkingLevel(level: domain.ThinkingLevel): LlmWireThinkingLevel {
    match (level) {
        case domain.ThinkingLevel.Off => LlmWireThinkingLevel.Off
        case domain.ThinkingLevel.Minimal => LlmWireThinkingLevel.Minimal
        case domain.ThinkingLevel.Low => LlmWireThinkingLevel.Low
        case domain.ThinkingLevel.Medium => LlmWireThinkingLevel.Medium
        case domain.ThinkingLevel.High => LlmWireThinkingLevel.High
        case domain.ThinkingLevel.XHigh => LlmWireThinkingLevel.XHigh
        case domain.ThinkingLevel.Max => LlmWireThinkingLevel.Max
    }
}

func toLlmWireThinkingControl(
    request: domain.ModelRequest,
    protocol: ProviderProtocol
): LlmWireThinkingControl {
    match (request.resolvedPolicy) {
        case Some(policy) =>
            if (let domain.ThinkingLevel.Off <- policy.thinking.effective) {
                LlmWireThinkingControl.Disabled
            } else {
                match (policy.thinking.mode) {
                    case domain.ThinkingControlMode.NoThinking => LlmWireThinkingControl.Disabled
                    case domain.ThinkingControlMode.Toggle => LlmWireThinkingControl.Toggle(true)
                    case domain.ThinkingControlMode.Effort =>
                        LlmWireThinkingControl.Effort(toLlmWireThinkingLevel(policy.thinking.effective))
                    case domain.ThinkingControlMode.Budget => match (policy.thinking.budgetTokens) {
                        case Some(value) => LlmWireThinkingControl.Budget(value)
                        case None => throw IllegalArgumentException("resolved budget thinking has no token budget")
                    }
                    case domain.ThinkingControlMode.Adaptive => match (policy.thinking.adaptiveEffort) {
                        case Some(value) => LlmWireThinkingControl.Adaptive(Some(toLlmWireThinkingLevel(value)))
                        case None => LlmWireThinkingControl.Adaptive(None)
                    }
                }
            }
        case None =>
            if (let domain.ThinkingLevel.Off <- request.thinking) {
                LlmWireThinkingControl.Disabled
            } else {
                match (protocol) {
                    case ProviderProtocol.Messages =>
                        LlmWireThinkingControl.Budget(domain.defaultThinkingBudget(request.thinking))
                    case _ => LlmWireThinkingControl.Effort(toLlmWireThinkingLevel(request.thinking))
                }
            }
    }
}

func toLlmWireRequest(request: domain.ModelRequest, protocol: ProviderProtocol): LlmWireRequest {
    let messages = ArrayList<LlmWireMessage>()
    for (message in request.messages) {
        let blocks = ArrayList<LlmWireBlock>()
        for (block in message.blocks) {
            let image: ?LlmWireImage = match (block.image) {
                case Some(value) => Some(LlmWireImage(
                    match (value.sourceKind) {
                        case domain.ModelImageSourceKind.Url => LlmWireImageSourceKind.Url
                        case domain.ModelImageSourceKind.Base64 => LlmWireImageSourceKind.Base64
                    },
                    value.data,
                    mediaType: value.mediaType,
                    detail: match (value.detail) {
                        case domain.ModelImageDetail.Auto => LlmWireImageDetail.Auto
                        case domain.ModelImageDetail.Low => LlmWireImageDetail.Low
                        case domain.ModelImageDetail.High => LlmWireImageDetail.High
                    }
                ))
                case None => None
            }
            let state: ?LlmWireOpaqueState = match (block.opaqueState) {
                case Some(value) => Some(LlmWireOpaqueState(
                    value.protocol, value.payload, itemId: value.itemId
                ))
                case None => None
            }
            blocks.add(LlmWireBlock(
                match (block.kind) {
                    case domain.ModelBlockKind.Text => LlmWireBlockKind.Text
                    case domain.ModelBlockKind.Image => LlmWireBlockKind.Image
                    case domain.ModelBlockKind.Reasoning => LlmWireBlockKind.Reasoning
                    case domain.ModelBlockKind.ToolCall => LlmWireBlockKind.ToolCall
                    case domain.ModelBlockKind.ToolResult => LlmWireBlockKind.ToolResult
                    case domain.ModelBlockKind.Refusal => LlmWireBlockKind.Refusal
                    case domain.ModelBlockKind.Error => LlmWireBlockKind.Error
                    case domain.ModelBlockKind.Unknown => LlmWireBlockKind.Unknown
                },
                text: block.text,
                callId: block.callId,
                name: block.name,
                arguments: block.arguments,
                isError: block.isError,
                image: image,
                opaqueState: state
            ))
        }
        messages.add(LlmWireMessage(
            match (message.role) {
                case domain.ModelRole.User => LlmWireRole.User
                case domain.ModelRole.Assistant => LlmWireRole.Assistant
            },
            blocks.toArray()
        ))
    }
    let tools = ArrayList<LlmWireTool>()
    for (tool in request.tools) { tools.add(LlmWireTool(tool.name, tool.description, tool.inputSchema)) }
    let structured: ?LlmWireStructuredOutput = match (request.structuredOutput) {
        case Some(value) => Some(LlmWireStructuredOutput(
            value.name, value.schema, description: value.description, strict: value.strict
        ))
        case None => None
    }
    LlmWireRequest(
        request.model,
        messages.toArray(),
        system: request.system,
        tools: tools.toArray(),
        thinking: toLlmWireThinkingControl(request, protocol),
        maxOutputTokens: request.wireMaxOutputTokens,
        streaming: request.streaming,
        parallelToolCalls: request.parallelToolCalls,
        serviceTier: request.serviceTier,
        cachePolicy: match (request.cachePolicy) {
            case domain.ModelCachePolicy.Default => LlmWireCachePolicy.Default
            case domain.ModelCachePolicy.StablePrefix => LlmWireCachePolicy.StablePrefix
        },
        cacheKey: request.cacheKey,
        toolChoice: match (request.toolChoice) {
            case domain.ModelToolChoice.Auto => LlmWireToolChoice.Auto
            case domain.ModelToolChoice.NoTools => LlmWireToolChoice.NoTools
            case domain.ModelToolChoice.Required => LlmWireToolChoice.Required
        },
        structuredOutput: structured
    )
}

public func encodeMessagesRequest(request: domain.ModelRequest): String {
    encodeMessagesWireRequest(toLlmWireRequest(request, ProviderProtocol.Messages))
}

public func encodeDeepSeekMessagesRequest(request: domain.ModelRequest): String {
    encodeDeepSeekMessagesWireRequest(toLlmWireRequest(request, ProviderProtocol.Messages))
}

public func encodeResponsesRequest(request: domain.ModelRequest): String {
    encodeResponsesWireRequest(toLlmWireRequest(request, ProviderProtocol.Responses))
}

public func encodeCompletionsRequest(request: domain.ModelRequest): String {
    encodeChatCompletionsWireRequest(toLlmWireRequest(request, ProviderProtocol.Completions))
}

public func encodeDeepSeekChatRequest(request: domain.ModelRequest): String {
    encodeDeepSeekChatWireRequest(toLlmWireRequest(request, ProviderProtocol.Completions))
}

func decodeProviderReply(
    provider: ProviderSpec,
    body: String,
    streaming: Bool,
    events: domain.ModelEventSink,
    structuredOutput: ?domain.StructuredOutputSpec
): domain.Result<domain.ModelReply> {
    try {
        let terminal = if (streaming) {
            decodeEventStream(body, provider.protocol, events).terminalSource
        } else {
            body
        }
        let reply = match (provider.protocol) {
            case ProviderProtocol.Messages => decodeMessagesReply(
                terminal, provider.id, streaming: streaming
            )
            case ProviderProtocol.Responses => decodeResponsesReply(
                terminal, provider.id, streaming: streaming
            )
            case ProviderProtocol.Completions => decodeCompletionsReply(
                terminal, provider.id, streaming: streaming
            )
        }
        match (reply.completionDisposition) {
            case domain.CompletionDisposition.Complete |
                 domain.CompletionDisposition.ToolUse => ()
            // Output-limited is a valid provider terminal fact, not a valid
            // Decision. Preserve the normalized reply so AgentCore can apply
            // its durable child-Attempt recovery policy.
            case domain.CompletionDisposition.OutputLimited =>
                return domain.Result.Ok(reply)
            case _ => return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Protocol,
                "model.decision_terminal_unaccepted",
                "provider response ended without an accepted decision boundary",
                retryable: true,
                fallbackAllowed: true,
                fields: [
                    domain.ErrorField("provider_profile_id", provider.id),
                    domain.ErrorField("api_protocol", providerProtocolName(provider.protocol)),
                    domain.ErrorField("stop_reason", reply.stopReason),
                    domain.ErrorField(
                        "completion_disposition",
                        completionDispositionName(reply.completionDisposition)
                    )
                ]
            ))
        }
        if (!reply.acceptedOutput) {
            return domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Provider,
                    "model.output_rejected",
                    "model provider returned no accepted output",
                    retryable: true,
                    fallbackAllowed: true
                )
            )
        }
        attachStructuredOutput(reply, structuredOutput)
    } catch (error: LlmTransportError) {
        let fields = ArrayList<domain.ErrorField>()
        fields.add(domain.ErrorField("provider_id", provider.id))
        fields.add(domain.ErrorField("llm_error_kind", llmTransportErrorKindName(error.kind)))
        if (error.providerErrorCode != "") { fields.add(domain.ErrorField("provider_error_code", error.providerErrorCode)) }
        if (error.providerErrorType != "") { fields.add(domain.ErrorField("provider_error_type", error.providerErrorType)) }
        match (error.httpStatus) { case Some(value) => fields.add(domain.ErrorField("http_status", value.toString())); case None => () }
        if (error.retryAfterMillis > 0) { fields.add(domain.ErrorField("retry_after_millis", error.retryAfterMillis.toString())) }
        domain.Result.Err(domain.AgentError(
            match (error.kind) {
                case LlmTransportErrorKind.Cancelled => domain.AgentErrorKind.Cancelled
                case LlmTransportErrorKind.Deadline => domain.AgentErrorKind.Timeout
                case LlmTransportErrorKind.Http | LlmTransportErrorKind.Transport => domain.AgentErrorKind.Transport
                case _ => domain.AgentErrorKind.Protocol
            },
            error.code,
            error.message,
            retryable: error.retryable,
            fallbackAllowed: true,
            fields: fields.toArray()
        ))
    } catch (error: Exception) {
        domain.Result.Err(
            domain.AgentError(
                domain.AgentErrorKind.Protocol,
                "model.invalid_response",
                error.message,
                fields: [domain.ErrorField("provider_id", provider.id)]
            )
        )
    }
}

func llmTransportErrorKindName(kind: LlmTransportErrorKind): String {
    match (kind) {
        case LlmTransportErrorKind.InvalidWire => "invalid_wire"
        case LlmTransportErrorKind.Http => "http"
        case LlmTransportErrorKind.BodyLimit => "body_limit"
        case LlmTransportErrorKind.Sse => "sse"
        case LlmTransportErrorKind.Cancelled => "cancelled"
        case LlmTransportErrorKind.Deadline => "deadline"
        case LlmTransportErrorKind.Transport => "transport"
    }
}

func attachStructuredOutput(
    reply: domain.ModelReply,
    spec: ?domain.StructuredOutputSpec
): domain.Result<domain.ModelReply> {
    let requested = match (spec) {
        case Some(value) => value
        case None => return domain.Result.Ok(reply)
    }
    var source = ""
    for (block in reply.blocks) {
        match (block.kind) {
            case domain.ModelBlockKind.ToolCall =>
                // A tool-use response is an intermediate Agent turn. The
                // output grammar applies again when the model answers
                // directly after receiving tool results.
                return domain.Result.Ok(reply)
            case domain.ModelBlockKind.Refusal =>
                return domain.Result.Err(domain.AgentError(
                    domain.AgentErrorKind.Provider,
                    "model.structured_output_refused",
                    if (block.text == "") {
                        "model refused to produce structured output"
                    } else {
                        block.text
                    },
                    fallbackAllowed: true
                ))
            case domain.ModelBlockKind.Text => source += block.text
            case _ => ()
        }
    }
    if (source.trimAscii() == "") {
        return domain.Result.Err(domain.AgentError(
            domain.AgentErrorKind.Protocol,
            "model.structured_output_missing",
            "model returned no structured JSON output",
            retryable: true,
            fallbackAllowed: true
        ))
    }
    let value = match (decodeAgentValue(source)) {
        case domain.Result.Ok(parsed) => parsed
        case domain.Result.Err(error) => return domain.Result.Err(domain.AgentError(
            domain.AgentErrorKind.Protocol,
            "model.structured_output_invalid_json",
            error.message,
            retryable: true,
            fallbackAllowed: true
        ))
    }
    match (domain.validateAgentValueSchema(requested.schema, value)) {
        case Some(violation) => return domain.Result.Err(domain.AgentError(
            domain.AgentErrorKind.Protocol,
            "model.structured_output_schema_violation",
            violation.message,
            retryable: true,
            fallbackAllowed: true,
            fields: [
                domain.ErrorField("path", violation.path),
                domain.ErrorField("keyword", violation.keyword)
            ]
        ))
        case None => ()
    }
    domain.Result.Ok(domain.ModelReply(
        reply.blocks,
        stopReason: reply.stopReason,
        usage: Some(reply.usage),
        acceptedOutput: reply.acceptedOutput,
        providerId: reply.providerId,
        responseId: reply.responseId,
        structuredOutput: Some(value),
        terminalEvidence: reply.terminalEvidence,
        completionDisposition: reply.completionDisposition,
        decisionOutcome: reply.decisionOutcome,
        validationVersion: reply.validationVersion
    ))
}

func fromLlmWireReply(
    reply: LlmWireReply,
    providerId: String,
    protocol: ProviderProtocol,
    streaming: Bool
): domain.ModelReply {
    let blocks = ArrayList<domain.ModelBlock>()
    for (block in reply.blocks) {
        let state: ?domain.OpaqueProviderState = match (block.opaqueState) {
            case Some(value) => Some(domain.OpaqueProviderState(
                providerId,
                value.protocol,
                value.payload,
                itemId: value.itemId,
                replayRequired: true
            ))
            case None => None
        }
        blocks.add(domain.ModelBlock(
            match (block.kind) {
                case LlmWireBlockKind.Text => domain.ModelBlockKind.Text
                case LlmWireBlockKind.Image => domain.ModelBlockKind.Image
                case LlmWireBlockKind.Reasoning => domain.ModelBlockKind.Reasoning
                case LlmWireBlockKind.ToolCall => domain.ModelBlockKind.ToolCall
                case LlmWireBlockKind.ToolResult => domain.ModelBlockKind.ToolResult
                case LlmWireBlockKind.Refusal => domain.ModelBlockKind.Refusal
                case LlmWireBlockKind.Error => domain.ModelBlockKind.Error
                case LlmWireBlockKind.Unknown => domain.ModelBlockKind.Unknown
            },
            text: block.text,
            callId: block.callId,
            name: block.name,
            arguments: block.arguments,
            isError: block.isError,
            opaqueState: state
        ))
    }
    let outcome = decisionOutcomeFrom(blocks.toArray())
    let disposition = completionDispositionFrom(protocol, reply.stopReason, outcome)
    let usageEventKind = if (streaming) {
        match (protocol) {
            case ProviderProtocol.Messages => "message_stop"
            case ProviderProtocol.Responses => "response.completed"
            case ProviderProtocol.Completions => "finish_reason"
        }
    } else {
        "response_body"
    }
    domain.ModelReply(
        blocks.toArray(),
        stopReason: reply.stopReason,
        usage: Some(domain.ModelUsage(
            inputTokens: reply.usage.inputTokens,
            outputTokens: reply.usage.outputTokens,
            reasoningTokens: reply.usage.reasoningTokens,
            cacheReadTokens: reply.usage.cacheReadTokens,
            cacheWriteTokens: reply.usage.cacheWriteTokens,
            source: if (streaming) {
                domain.ModelUsageSource.ProviderStreamFinal
            } else {
                domain.ModelUsageSource.ProviderFinal
            },
            evidence: Some(domain.ModelUsageEvidence(
                providerProtocolName(protocol),
                usageEventKind,
                providerResponseId: reply.responseId
            ))
        )),
        acceptedOutput: !blocks.isEmpty() && match (disposition) {
            case domain.CompletionDisposition.OutputLimited |
                domain.CompletionDisposition.ProtocolIncomplete => false
            case _ => true
        },
        providerId: providerId,
        responseId: reply.responseId,
        terminalEvidence: Some(domain.TerminalEvidence(
            providerProtocolName(protocol),
            usageEventKind,
            rawStopReason: reply.stopReason,
            messageTerminalObserved: true,
            streamEofObserved: true,
            adapterVersion: "llm4cj-wire-v2"
        )),
        completionDisposition: disposition,
        decisionOutcome: outcome,
        validationVersion: 1
    )
}

func decisionOutcomeFrom(blocks: Array<domain.ModelBlock>): domain.DecisionOutcome {
    var refusal = false
    for (block in blocks) {
        match (block.kind) {
            case domain.ModelBlockKind.ToolCall => return domain.DecisionOutcome.ToolCalls
            case domain.ModelBlockKind.Refusal => refusal = true
            case _ => ()
        }
    }
    if (refusal) { domain.DecisionOutcome.Refusal } else { domain.DecisionOutcome.Response }
}

func completionDispositionFrom(
    protocol: ProviderProtocol,
    raw: String,
    outcome: domain.DecisionOutcome
): domain.CompletionDisposition {
    let terminal = match (protocol) {
        case ProviderProtocol.Messages => match (raw) {
            case "end_turn" | "stop_sequence" => domain.CompletionDisposition.Complete
            case "tool_use" => domain.CompletionDisposition.ToolUse
            case "max_tokens" => domain.CompletionDisposition.OutputLimited
            case "refusal" => domain.CompletionDisposition.Complete
            case _ => domain.CompletionDisposition.Unknown
        }
        case ProviderProtocol.Responses => match (raw) {
            case "completed" => domain.CompletionDisposition.Complete
            case "incomplete" => domain.CompletionDisposition.OutputLimited
            case "failed" | "cancelled" => domain.CompletionDisposition.ProtocolIncomplete
            case _ => domain.CompletionDisposition.Unknown
        }
        case ProviderProtocol.Completions => match (raw) {
            case "stop" => domain.CompletionDisposition.Complete
            case "tool_calls" | "function_call" => domain.CompletionDisposition.ToolUse
            case "length" | "max_tokens" => domain.CompletionDisposition.OutputLimited
            case "content_filter" => domain.CompletionDisposition.Filtered
            case _ => domain.CompletionDisposition.Unknown
        }
    }
    match (terminal) {
        case domain.CompletionDisposition.Complete => match (outcome) {
            case domain.DecisionOutcome.ToolCalls => domain.CompletionDisposition.ToolUse
            case _ => terminal
        }
        case _ => terminal
    }
}

func completionDispositionName(value: domain.CompletionDisposition): String {
    match (value) {
        case domain.CompletionDisposition.Complete => "complete"
        case domain.CompletionDisposition.ToolUse => "tool_use"
        case domain.CompletionDisposition.OutputLimited => "output_limited"
        case domain.CompletionDisposition.Filtered => "filtered"
        case domain.CompletionDisposition.ProtocolIncomplete => "protocol_incomplete"
        case domain.CompletionDisposition.Unknown => "unknown"
    }
}

func decodeMessagesReply(
    source: String,
    providerId: String,
    streaming!: Bool = false
): domain.ModelReply {
    fromLlmWireReply(
        decodeMessagesWireReply(source, provider: providerId),
        providerId,
        ProviderProtocol.Messages,
        streaming
    )
}

func decodeResponsesReply(
    source: String,
    providerId: String,
    streaming!: Bool = false
): domain.ModelReply {
    fromLlmWireReply(
        decodeResponsesWireReply(source, provider: providerId),
        providerId,
        ProviderProtocol.Responses,
        streaming
    )
}

func decodeCompletionsReply(
    source: String,
    providerId: String,
    streaming!: Bool = false
): domain.ModelReply {
    fromLlmWireReply(
        decodeChatCompletionsWireReply(source, provider: providerId),
        providerId,
        ProviderProtocol.Completions,
        streaming
    )
}

func decodeEventStream(
    source: String,
    protocol: ProviderProtocol,
    events: domain.ModelEventSink
): LlmWireStreamResult {
    let result = decodeLlmWireEventStream(
        match (protocol) {
            case ProviderProtocol.Messages => LlmWireProtocol.Messages
            case ProviderProtocol.Responses => LlmWireProtocol.Responses
            case ProviderProtocol.Completions => LlmWireProtocol.ChatCompletions
        },
        source
    )
    for (event in result.events) { emitLlmWireEvent(event, protocol, events) }
    result
}

func validateModelRequestContent(request: domain.ModelRequest): domain.Result<Unit> {
    for (message in request.messages) {
        for (block in message.blocks) {
            match (block.kind) {
            case domain.ModelBlockKind.Image =>
                let userRole = match (message.role) {
                    case domain.ModelRole.User => true
                    case domain.ModelRole.Assistant => false
                }
                if (!userRole) {
                    return domain.Result.Err(domain.AgentError(
                        domain.AgentErrorKind.InvalidInput,
                        "model.image_role_invalid",
                        "image input is only valid in user messages"
                    ))
                }
                if (block.image.isNone()) {
                    return domain.Result.Err(domain.AgentError(
                        domain.AgentErrorKind.InvalidInput,
                        "model.image_missing",
                        "image model block is missing image content"
                    ))
                }
            case _ =>
                if (block.image.isSome()) {
                return domain.Result.Err(domain.AgentError(
                    domain.AgentErrorKind.InvalidInput,
                    "model.image_block_kind_invalid",
                    "image content requires an image model block"
                ))
                }
            }
        }
    }
    domain.Result.Ok(())
}


func jsonErrorKindName(kind: JsonErrorKind): String {
    match (kind) {
        case JsonErrorKind.InvalidSyntax => "invalid_syntax"
        case JsonErrorKind.ResourceLimit => "resource_limit"
        case JsonErrorKind.InvalidValue => "invalid_value"
        case JsonErrorKind.EncodingLimit => "encoding_limit"
    }
}

func messageText(message: domain.ModelMessage): String {
    var result = ""
    for (block in message.blocks) {
        match (block.kind) {
            case domain.ModelBlockKind.Text => result += block.text
            case _ => ()
        }
    }
    result
}

func curlConfig(provider: ProviderSpec, apiKey: String, streaming: Bool): String {
    var result = ""
    for (header in effectiveProviderHeaders(provider, streaming)) {
        result += "header = \"" + header.name + ": " + header.value + "\"\n"
    }
    match (provider.protocol) {
        case ProviderProtocol.Messages =>
            result += "header = \"x-api-key: " + apiKey + "\"\n"
        case ProviderProtocol.Responses => result += "header = \"authorization: Bearer " + apiKey + "\"\n"
        case ProviderProtocol.Completions => result += "header = \"authorization: Bearer " + apiKey + "\"\n"
    }
    result
}

// Expose the non-secret protocol headers as a contract boundary so transports
// other than curl, and focused adapter tests, cannot silently diverge from the
// Messages fast-mode wire contract.
public func providerBetaHeaders(provider: ProviderSpec): Array<String> {
    match (provider.protocol) {
        case ProviderProtocol.Messages => if (provider.messagesFastMode) {
            ["anthropic-beta: fast-mode-2026-02-01"]
        } else {
            []
        }
        case _ => []
    }
}

func configurationError(name: String): domain.Result<String> {
    domain.Result.Err(
        domain.AgentError(
            domain.AgentErrorKind.Configuration,
            "model.missing_api_key",
            "provider API key is missing: " + name,
            fields: [domain.ErrorField("environment", name)]
        )
    )
}

func defaultProviderCredential(provider: ProviderSpec): domain.Result<String> {
    match (getVariable(provider.apiKeyEnv)) {
        case Some(value) =>
            if (value.trimAscii() != "") {
                return domain.Result.Ok(value)
            }
        case None => ()
    }
    if (provider.credentialFile != "" && exists(Path(provider.credentialFile))) {
        try {
            let value = String.fromUtf8(File.readFrom(provider.credentialFile)).trimAscii()
            if (value != "") {
                return domain.Result.Ok(value)
            }
        } catch (error: Exception) {
            return domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Configuration,
                    "model.credential_file_invalid",
                    "cannot read provider credential: " + error.message,
                    fields: [
                        domain.ErrorField(
                            "path",
                            provider.credentialFile
                        )
                    ]
                )
            )
        }
    }
    configurationError(provider.apiKeyEnv)
}

func removeFile(path: String): Unit {
    try {
        let (_, _, _) = executeWithOutput("rm", ["-f", path])
    } catch (_: Exception) {
        ()
    }
}
