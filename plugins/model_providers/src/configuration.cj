package native_model_providers

import agent_domain.*
import model_adapters.*
import model_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

let MODEL_CONTRIBUTIONS = ["openai-chat-completions", "openai-responses", "anthropic-messages"]

func apiBinding(contribution: String, dialect: String): ModelApiBinding {
    match ((contribution, dialect)) {
        case ("openai-chat-completions", "openai_chat") => ModelApiBinding(LlmApiId.OpenAiChatCompletions,
            TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.OpenAi))
        case ("openai-chat-completions", "deepseek_chat") => ModelApiBinding(LlmApiId.OpenAiChatCompletions,
            TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.DeepSeek))
        case ("openai-chat-completions", "generic_chat") => ModelApiBinding(LlmApiId.OpenAiChatCompletions,
            TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.Generic))
        case ("openai-responses", "openai_responses") => ModelApiBinding(LlmApiId.OpenAiResponses,
            TypedProviderDialect.OpenAiResponses(OpenAiResponsesDialect.OpenAi))
        case ("openai-responses", "deepseek_responses") => ModelApiBinding(LlmApiId.OpenAiResponses,
            TypedProviderDialect.OpenAiResponses(OpenAiResponsesDialect.DeepSeek))
        case ("anthropic-messages", "anthropic_messages") => ModelApiBinding(LlmApiId.AnthropicMessages,
            TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.Anthropic))
        case ("anthropic-messages", "deepseek_messages") => ModelApiBinding(LlmApiId.AnthropicMessages,
            TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.DeepSeek))
        case ("anthropic-messages", "generic_messages") => ModelApiBinding(LlmApiId.AnthropicMessages,
            TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.Generic))
        case _ => throw ModelWireFailure("model.plugin_dialect_mismatch")
    }
}

class ModelConfiguration {
    let profile: RuntimeProviderProfile
    let model: RuntimeModelDescriptor
    let refs: Array<String>
    init(binding: AgentValue) {
        let config = field(binding, "configuration")
        exact(config, ["base_url", "provider", "dialect", "headers", "timeout_ms", "allow_insecure_http"])
        let timeout = num(config, "timeout_ms")
        need(timeout >= 0)
        let url = txt(config, "base_url")
        need(url.size <= 4096 && (url.startsWith("https://") || (flag(config, "allow_insecure_http") && url.startsWith("http://"))))
        let rawHeaders = field(config, "headers"); need(rawHeaders.unifiedKind == ValueKind.Object && rawHeaders.fields.size <= 32)
        let headers = ArrayList<ProviderHeader>()
        for (header in rawHeaders.fields) {
            need(header.value.unifiedKind == ValueKind.Text && header.value.text.size <= 4096)
            // Existing typed provider validation rejects auth/host/cookie and
            // control characters. Secret injection remains entirely in host.
            headers.add(ProviderHeader(header.name, header.value.text))
        }
        let credentialRefs = field(binding, "credential_refs")
        need(credentialRefs.unifiedKind == ValueKind.List && credentialRefs.items.size <= 16)
        let refs = ArrayList<String>()
        for (reference in credentialRefs.items) {
            need(reference.unifiedKind == ValueKind.Text && reference.text != "" && reference.text.size <= 256)
            need(!refs.contains(reference.text)); refs.add(reference.text)
        }
        this.refs = refs.toArray()
        let capabilities = modelProviderBindingCapabilities(binding)
        let profileId = txt(binding, "provider_id")
        // This required legacy API field is a nonsecret name only. The injected
        // broker transport never calls EnvironmentFileCredentialResolver.
        this.profile = RuntimeProviderProfile(profileId, txt(config, "provider"), url,
            "AXYNDRA_OPAQUE_MODEL_CREDENTIAL", allowInsecureHttp: flag(config, "allow_insecure_http"),
            timeoutMillis: timeout, defaultHeaders: headers.toArray())
        this.model = RuntimeModelDescriptor(txt(binding, "model"), profileId, txt(binding, "wire_model"),
            apiBinding(txt(binding, "contribution"), txt(config, "dialect")), capabilities)
    }
    func adapter(transport: ProviderTransport): LlmApiAdapter {
        match (model.apiBinding.apiId) {
            case LlmApiId.OpenAiChatCompletions => OpenAiChatCompletionsAdapter(transport: transport)
            case LlmApiId.OpenAiResponses => OpenAiResponsesAdapter(transport: transport)
            case LlmApiId.AnthropicMessages => AnthropicMessagesAdapter(transport: transport)
        }
    }
}
