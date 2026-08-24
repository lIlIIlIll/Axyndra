package agent_product

import agent_domain.*
import model_adapters.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProviderDialectTests {
    @TestCase
    func explicitDeepSeekDialectIsPreserved(): Unit {
        let profile = ProviderProfile(
            "DEEPSEEK",
            "anthropic",
            "messages",
            "https://api.deepseek.com/anthropic",
            "DEEPSEEK_API_KEY",
            dialect: "deepseek_messages"
        )

        @Expect(match (productProviderDialect(profile)) {
            case ProviderDialect.DeepSeekMessages => true
            case _ => false
        })
    }

    @TestCase
    func explicitAnthropicDialectIsPreserved(): Unit {
        let profile = ProviderProfile(
            "anthropic-official",
            "anthropic",
            "messages",
            "https://api.anthropic.com",
            "ANTHROPIC_API_KEY",
            dialect: "anthropic_messages"
        )

        @Expect(match (productProviderDialect(profile)) {
            case ProviderDialect.AnthropicMessages => true
            case _ => false
        })
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
