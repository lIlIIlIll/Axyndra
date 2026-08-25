package model_adapters

import agent_domain as domain
import agent_ports as ports

public enum LlmApiId {
    OpenAiChatCompletions | OpenAiResponses | AnthropicMessages
}

public enum OpenAiCompletionsDialect {
    OpenAi | DeepSeek | Generic
}

public enum OpenAiResponsesDialect {
    OpenAi
}

public enum AnthropicMessagesDialect {
    Anthropic | DeepSeek | Generic
}

// A closed typed sum keeps protocol-only compatibility switches out of the
// canonical request and prevents a dialect from being paired with another API.
public enum TypedProviderDialect {
    OpenAiCompletions(OpenAiCompletionsDialect)
    | OpenAiResponses(OpenAiResponsesDialect)
    | AnthropicMessages(AnthropicMessagesDialect)
}

public class ModelApiBinding {
    public let apiId: LlmApiId
    public let dialect: TypedProviderDialect

    public init(apiId: LlmApiId, dialect: TypedProviderDialect) {
        if (!typedDialectMatchesApi(apiId, dialect)) {
            throw IllegalArgumentException("model API dialect does not match its wire API")
        }
        this.apiId = apiId
        this.dialect = dialect
    }
}

public class RuntimeProviderProfile {
    public let id: String
    public let provider: String
    public let baseUrl: String
    public let apiKeyEnv: String
    public let authentication: String
    public let credentialFile: String
    public let timeoutMillis: Int64
    public let defaultHeaders: Array<ProviderHeader>
    public let endpointMaxOutputTokens: ?Int64

    public init(
        id: String,
        provider: String,
        baseUrl: String,
        apiKeyEnv: String,
        authentication!: String = "api-key",
        credentialFile!: String = "",
        timeoutMillis!: Int64 = 120000,
        defaultHeaders!: Array<ProviderHeader> = [],
        endpointMaxOutputTokens!: ?Int64 = None
    ) {
        if (id.trimAscii() == "" || provider.trimAscii() == "" ||
            baseUrl.trimAscii() == "" ||
            (authentication == "api-key" && apiKeyEnv.trimAscii() == "") ||
            (authentication != "api-key" && authentication != "oauth") ||
            timeoutMillis < 0) {
            throw IllegalArgumentException("runtime provider profile is invalid")
        }
        this.id = id.trimAscii()
        this.provider = provider.trimAscii()
        this.baseUrl = baseUrl.trimAscii().removeSuffix("/")
        this.apiKeyEnv = apiKeyEnv.trimAscii()
        this.authentication = authentication
        this.credentialFile = credentialFile
        this.timeoutMillis = timeoutMillis
        this.defaultHeaders = defaultHeaders
        this.endpointMaxOutputTokens = endpointMaxOutputTokens
    }
}

public class RuntimeModelDescriptor {
    public let displayId: String
    public let profileId: String
    public let wireModelId: String
    public let apiBinding: ModelApiBinding
    public let capabilities: domain.ModelCapabilities
    public let defaultHeaders: Array<ProviderHeader>

    public init(
        displayId: String,
        profileId: String,
        wireModelId: String,
        apiBinding: ModelApiBinding,
        capabilities: domain.ModelCapabilities,
        defaultHeaders!: Array<ProviderHeader> = []
    ) {
        if (displayId.trimAscii() == "" || profileId.trimAscii() == "" ||
            wireModelId.trimAscii() == "") {
            throw IllegalArgumentException("runtime model descriptor is invalid")
        }
        this.displayId = displayId.trimAscii()
        this.profileId = profileId.trimAscii()
        this.wireModelId = wireModelId.trimAscii()
        this.apiBinding = apiBinding
        this.capabilities = capabilities
        this.defaultHeaders = defaultHeaders
    }
}

public interface LlmApiAdapter {
    func apiId(): LlmApiId
    func execute(
        profile: RuntimeProviderProfile,
        model: RuntimeModelDescriptor,
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply>
    func cancel(requestId: String): domain.Result<Unit>
}

abstract class TypedLlmApiAdapter <: LlmApiAdapter {
    protected let transport: ProviderTransport
    protected init(transport: ProviderTransport) { this.transport = transport }

    protected func dispatch(
        profile: RuntimeProviderProfile,
        model: RuntimeModelDescriptor,
        request: domain.ModelRequest,
        protocol: ProviderProtocol,
        dialect: ProviderDialect,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        ProviderModelPort(ProviderSpec(
            profile.id, protocol, model.wireModelId, profile.baseUrl,
            profile.apiKeyEnv,
            credentialFile: profile.credentialFile,
            timeoutMillis: profile.timeoutMillis,
            provider: profile.provider,
            dialect: Some(dialect),
            endpointMaxOutputTokens: profile.endpointMaxOutputTokens,
            capabilities: model.capabilities,
            profileHeaders: profile.defaultHeaders,
            modelHeaders: model.defaultHeaders
        ), transport).execute(withRuntimeWireModel(request, model.wireModelId), events)
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        transport.cancel(requestId)
    }
}

public class OpenAiChatCompletionsAdapter <: TypedLlmApiAdapter {
    public init(transport!: ProviderTransport = NativeProviderTransport()) { super(transport) }
    public func apiId(): LlmApiId { LlmApiId.OpenAiChatCompletions }
    public func execute(
        profile: RuntimeProviderProfile,
        model: RuntimeModelDescriptor,
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        let dialect = match (model.apiBinding.dialect) {
            case TypedProviderDialect.OpenAiCompletions(value) => match (value) {
                case OpenAiCompletionsDialect.OpenAi => ProviderDialect.OpenAiChat
                case OpenAiCompletionsDialect.DeepSeek => ProviderDialect.DeepSeekChat
                case OpenAiCompletionsDialect.Generic => ProviderDialect.GenericChat
            }
            case _ => return dialectMismatch(profile, model)
        }
        dispatch(profile, model, request, ProviderProtocol.Completions, dialect, events)
    }
}

public class OpenAiResponsesAdapter <: TypedLlmApiAdapter {
    public init(transport!: ProviderTransport = NativeProviderTransport()) { super(transport) }
    public func apiId(): LlmApiId { LlmApiId.OpenAiResponses }
    public func execute(
        profile: RuntimeProviderProfile,
        model: RuntimeModelDescriptor,
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        match (model.apiBinding.dialect) {
            case TypedProviderDialect.OpenAiResponses(_) => dispatch(
                profile, model, request, ProviderProtocol.Responses,
                ProviderDialect.OpenAiResponses, events
            )
            case _ => dialectMismatch(profile, model)
        }
    }
}

public class AnthropicMessagesAdapter <: TypedLlmApiAdapter {
    public init(transport!: ProviderTransport = NativeProviderTransport()) { super(transport) }
    public func apiId(): LlmApiId { LlmApiId.AnthropicMessages }
    public func execute(
        profile: RuntimeProviderProfile,
        model: RuntimeModelDescriptor,
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        let dialect = match (model.apiBinding.dialect) {
            case TypedProviderDialect.AnthropicMessages(value) => match (value) {
                case AnthropicMessagesDialect.Anthropic => ProviderDialect.AnthropicMessages
                case AnthropicMessagesDialect.DeepSeek => ProviderDialect.DeepSeekMessages
                case AnthropicMessagesDialect.Generic => ProviderDialect.GenericMessages
            }
            case _ => return dialectMismatch(profile, model)
        }
        dispatch(profile, model, request, ProviderProtocol.Messages, dialect, events)
    }
}

public class LlmApiAdapterRegistry {
    private let adapters: Array<LlmApiAdapter>
    public init(adapters: Array<LlmApiAdapter>) { this.adapters = adapters }
    public func resolve(apiId: LlmApiId): ?LlmApiAdapter {
        for (adapter in adapters where sameApiId(adapter.apiId(), apiId)) {
            return Some(adapter)
        }
        None
    }
    public func all(): Array<LlmApiAdapter> { adapters }
}

// Production ModelPort implementation. AgentCore remains unaware of profiles,
// wire APIs, dialects, credentials, HTTP, and SSE.
public class UnifiedModelRuntime <: ports.ModelPort {
    private let profiles: Array<RuntimeProviderProfile>
    private let models: Array<RuntimeModelDescriptor>
    private let apis: LlmApiAdapterRegistry

    public init(
        profiles: Array<RuntimeProviderProfile>,
        models: Array<RuntimeModelDescriptor>,
        apis: LlmApiAdapterRegistry
    ) {
        this.profiles = profiles
        this.models = models
        this.apis = apis
    }

    public func execute(
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        let model = match (runtimeModel(models, request.model)) {
            case Some(value) => value
            case None => return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Configuration,
                "model.descriptor_not_found",
                "model is not registered in the unified runtime",
                fields: [domain.ErrorField("model", request.model)]
            ))
        }
        let profile = match (runtimeProfile(profiles, model.profileId)) {
            case Some(value) => value
            case None => return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Configuration,
                "model.provider_profile_not_found",
                "model references an unavailable provider profile",
                fields: [
                    domain.ErrorField("provider_profile_id", model.profileId),
                    domain.ErrorField("model", model.displayId)
                ]
            ))
        }
        let adapter = match (apis.resolve(model.apiBinding.apiId)) {
            case Some(value) => value
            case None => return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Configuration,
                "model.api_adapter_not_registered",
                "model wire API has no registered adapter",
                fields: [
                    domain.ErrorField("provider_profile_id", profile.id),
                    domain.ErrorField("model", model.displayId),
                    domain.ErrorField("requested_api_id", llmApiIdName(model.apiBinding.apiId))
                ]
            ))
        }
        if (profile.authentication == "oauth") {
            return domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Configuration,
                "oauth_not_supported",
                "OAuth authentication is not implemented in Phase 1",
                fields: [domain.ErrorField("provider", profile.id)]
            ))
        }
        adapter.execute(profile, model, request, events)
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        var first: ?domain.AgentError = None
        for (adapter in apis.all()) {
            match (adapter.cancel(requestId)) {
                case domain.Result.Ok(_) => ()
                case domain.Result.Err(error) => if (first.isNone()) { first = Some(error) }
            }
        }
        match (first) {
            case Some(error) => domain.Result.Err(error)
            case None => domain.Result.Ok(())
        }
    }
}

public func defaultLlmApiRegistry(
    transport!: ProviderTransport = NativeProviderTransport()
): LlmApiAdapterRegistry {
    LlmApiAdapterRegistry([
        OpenAiChatCompletionsAdapter(transport: transport),
        OpenAiResponsesAdapter(transport: transport),
        AnthropicMessagesAdapter(transport: transport)
    ])
}

public func llmApiIdName(value: LlmApiId): String {
    match (value) {
        case LlmApiId.OpenAiChatCompletions => "openai_chat_completions"
        case LlmApiId.OpenAiResponses => "openai_responses"
        case LlmApiId.AnthropicMessages => "anthropic_messages"
    }
}

func sameApiId(left: LlmApiId, right: LlmApiId): Bool {
    llmApiIdName(left) == llmApiIdName(right)
}

func typedDialectMatchesApi(apiId: LlmApiId, dialect: TypedProviderDialect): Bool {
    match ((apiId, dialect)) {
        case (LlmApiId.OpenAiChatCompletions, TypedProviderDialect.OpenAiCompletions(_)) |
            (LlmApiId.OpenAiResponses, TypedProviderDialect.OpenAiResponses(_)) |
            (LlmApiId.AnthropicMessages, TypedProviderDialect.AnthropicMessages(_)) => true
        case _ => false
    }
}

func runtimeModel(values: Array<RuntimeModelDescriptor>, id: String): ?RuntimeModelDescriptor {
    for (value in values where value.displayId == id) { return Some(value) }
    None
}

func runtimeProfile(values: Array<RuntimeProviderProfile>, id: String): ?RuntimeProviderProfile {
    for (value in values where value.id == id) { return Some(value) }
    None
}

func dialectMismatch<T>(
    profile: RuntimeProviderProfile,
    model: RuntimeModelDescriptor
): domain.Result<T> {
    domain.Result.Err(domain.AgentError(
        domain.AgentErrorKind.Configuration,
        "model.api_dialect_mismatch",
        "model dialect is incompatible with its selected wire API",
        fields: [
            domain.ErrorField("provider_profile_id", profile.id),
            domain.ErrorField("model", model.displayId),
            domain.ErrorField("requested_api_id", llmApiIdName(model.apiBinding.apiId))
        ]
    ))
}

func withRuntimeWireModel(
    request: domain.ModelRequest,
    wireModelId: String
): domain.ModelRequest {
    domain.ModelRequest(
        wireModelId, request.messages, system: request.system,
        tools: request.tools, thinking: request.thinking,
        maxOutputTokens: request.maxOutputTokens,
        wireMaxOutputTokens: request.wireMaxOutputTokens,
        resolvedPolicy: request.resolvedPolicy,
        streaming: request.streaming,
        parallelToolCalls: request.parallelToolCalls,
        requestId: request.requestId,
        serviceTier: request.serviceTier,
        cachePolicy: request.cachePolicy,
        toolChoice: request.toolChoice,
        structuredOutput: request.structuredOutput,
        cacheKey: request.cacheKey,
        transportHardTimeoutMillis: request.transportHardTimeoutMillis
    )
}
