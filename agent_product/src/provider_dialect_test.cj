package agent_product

import agent_domain.*
import model_adapters.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProviderDialectTests {
    @TestCase
    func deepSeekMessagesDisablesParallelToolCalling(): Unit {
        let capabilities = productModelCapabilities(
            ModelCatalogEntry(
                "deepseek-v4-flash",
                providerProfile: "DEEPSEEK",
                thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking))
            ),
            dialect: "deepseek_messages"
        )

        @Expect(capabilities.toolCalling, true)
        @Expect(capabilities.parallelToolCalling, false)
    }

    @TestCase
    func deepSeekChatDisablesParallelToolCalling(): Unit {
        let capabilities = productModelCapabilities(
            ModelCatalogEntry(
                "deepseek-v4-flash",
                providerProfile: "DEEPSEEK",
                thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking))
            ),
            dialect: "deepseek_chat"
        )

        @Expect(capabilities.toolCalling, true)
        @Expect(capabilities.parallelToolCalling, false)
    }

    @TestCase
    func deepSeekResponsesDisablesParallelToolCalling(): Unit {
        let capabilities = productModelCapabilities(
            ModelCatalogEntry(
                "deepseek-v4-flash",
                providerProfile: "DEEPSEEK",
                thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking))
            ),
            dialect: "deepseek_responses"
        )

        @Expect(capabilities.toolCalling, true)
        @Expect(capabilities.parallelToolCalling, false)
    }

    @TestCase
    func deepSeekResponsesSetupUsesTypedResponsesBinding(): Unit {
        @Expect(
            configuredDialectForSetup(
                "deepseek",
                "responses",
                "https://api.deepseek.com"
            ),
            "deepseek_responses"
        )
        let profile = ProviderProfile(
            "deepseek",
            "deepseek",
            "responses",
            "https://api.deepseek.com",
            "DEEPSEEK_API_KEY",
            dialect: "deepseek_responses"
        )
        let entry = ModelCatalogEntry(
            "deepseek-v4-flash",
            providerProfile: "deepseek",
            apiId: "openai_responses",
            dialect: "deepseek_responses"
        )
        let binding = runtimeApiBinding(entry, profile)
        @Expect(
            match (binding.dialect) {
                case TypedProviderDialect.OpenAiResponses(OpenAiResponsesDialect.DeepSeek) => true
                case _ => false
            },
            true
        )
        @Expect(llmApiIdName(binding.apiId), "openai_responses")
    }

    @TestCase
    func deepSeekChatSetupKeepsEffortThinking(): Unit {
        let thinking = configuredThinkingForDialect("deepseek_chat")
        @Expect(
            match (thinking.mode) {
                case ThinkingControlMode.Effort => true
                case _ => false
            },
            true
        )
        @Expect(thinking.supportedLevels.size, 5)
    }

    @TestCase
    func openAiResponsesKeepsParallelToolCalling(): Unit {
        let capabilities = productModelCapabilities(
            ModelCatalogEntry(
                "gpt-5",
                providerProfile: "OPENAI",
                thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking))
            ),
            dialect: "openai_responses"
        )

        @Expect(capabilities.parallelToolCalling, true)
    }

    @TestCase
    func unspecifiedLimitsUseConservativeDefaults(): Unit {
        let capabilities = productModelCapabilities(
            ModelCatalogEntry(
                "deepseek-v4-flash",
                providerProfile: "DEEPSEEK",
                thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking))
            ),
            protocol: "messages",
            provider: "anthropic",
            baseUrl: "https://api.deepseek.com/anthropic"
        )

        @Expect(capabilities.contextWindowTokens, 128000)
        @Expect(capabilities.maxOutputTokens, 16384)
    }

    @TestCase
    func explicitDeepSeekLimitsRemainAuthoritative(): Unit {
        let capabilities = productModelCapabilities(
            ModelCatalogEntry(
                "deepseek-v4-flash",
                providerProfile: "DEEPSEEK",
                contextWindow: Some(200000),
                maxOutputTokens: Some(64000),
                thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking))
            ),
            protocol: "messages",
            provider: "anthropic",
            baseUrl: "https://api.deepseek.com/anthropic"
        )

        @Expect(capabilities.contextWindowTokens, 200000)
        @Expect(capabilities.maxOutputTokens, 64000)
    }
}
