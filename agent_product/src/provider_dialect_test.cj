package agent_product

import agent_domain.*
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
