package agent_product

import agent_domain.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProviderDialectTests {
    @TestCase
    func deepSeekMessagesDisablesParallelToolCalling(): Unit {
        let declared = installedNeutralCapabilities(128000)
        declared.put("parallel_tools", boolValue(false))
        let capabilities = parseProductNeutralModelPolicy(declared, modelPolicySha256Text("explicit-operator-config")).capabilities

        @Expect(capabilities.toolCalling, true)
        @Expect(capabilities.parallelToolCalling, false)
    }

    @TestCase
    func deepSeekChatDisablesParallelToolCalling(): Unit {
        let declared = installedNeutralCapabilities(128000)
        declared.put("parallel_tools", boolValue(false))
        let capabilities = parseProductNeutralModelPolicy(declared, modelPolicySha256Text("explicit-operator-config")).capabilities

        @Expect(capabilities.toolCalling, true)
        @Expect(capabilities.parallelToolCalling, false)
    }

    @TestCase
    func deepSeekResponsesDisablesParallelToolCalling(): Unit {
        let declared = installedNeutralCapabilities(128000)
        declared.put("parallel_tools", boolValue(false))
        let capabilities = parseProductNeutralModelPolicy(declared, modelPolicySha256Text("explicit-operator-config")).capabilities

        @Expect(capabilities.toolCalling, true)
        @Expect(capabilities.parallelToolCalling, false)
    }

    @TestCase
    func deepSeekResponsesSetupKeepsExplicitConfiguration(): Unit {
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
        @Expect(profile.protocol, "responses")
        @Expect(profile.dialect, "deepseek_responses")
        @Expect(entry.apiId, "openai_responses")
        @Expect(entry.dialect, "deepseek_responses")
        // Actual typed API dispatch now belongs to the independent package;
        // its protocol matrix exercises all eight explicit dialects.
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
        let capabilities = parseProductNeutralModelPolicy(installedNeutralCapabilities(128000),
            modelPolicySha256Text("explicit-parallel-true")).capabilities

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
