package agent_product

import agent_domain.*
import agent_host_runtime.*
import yjson.*

type ProductNeutralModelPolicy = HostNeutralModelPolicy
type ProductModelConfiguration = HostModelConfiguration
func parseProductNeutralModelPolicy(value: AgentValue, digest: String): ProductNeutralModelPolicy {
    parseHostNeutralModelPolicy(value, digest)
}
func loadProductModelConfiguration(settingsRoot: String, model: String): Result<ProductModelConfiguration> {
    loadHostModelConfiguration(settingsRoot, model)
}

func productRequestModelPolicy(settingsRoot: String, model: String, fixture: Bool): ProductNeutralModelPolicy {
    if (!fixture) {
        match (loadProductModelConfiguration(settingsRoot, model)) { case Result.Ok(value) => return value.policy; case Result.Err(_) => () }
    }
    // Product.request is a data-only, source-compatible constructor. Invalid
    // mappings get no features and no digest. InstalledPort validates metadata
    // before Core resolves policy or creates an Attempt. A later valid
    // mapping cannot match this empty fingerprint, so it cannot rescue a stale
    // request. Explicit fixture mode supplies its own test metadata above.
    ProductNeutralModelPolicy(ModelCapabilities(toolCalling: false, parallelToolCalling: false,
        reasoning: false, vision: false, structuredOutput: false, promptCache: false,
        contextWindowTokens: 4096, maxOutputTokens: 1024, thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking))), Option<Int64>.None, "")
}
